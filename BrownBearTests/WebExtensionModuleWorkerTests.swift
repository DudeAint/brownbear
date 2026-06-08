//
//  WebExtensionModuleWorkerTests.swift
//  BrownBearTests
//
//  Boots a REAL MV3 module service worker (manifest `"background": {"type":"module"}`) through the
//  shipping ESM linker runtime (brownbear-acorn.js + brownbear-esm-linker.js) in a JSContext, with a
//  virtual extension package supplying the module graph. Asserts the linker resolves and runs the
//  graph — named imports, namespace imports, relative path resolution, re-exports, and import.meta.url
//  — entirely in the engine production uses, then proves the linked code integrates with the chrome.*
//  runtime (a runtime.onMessage listener answers using imported values). Also covers the fail-closed
//  paths (missing module, parse error): the worker logs an error and registers no listener.
//
//  Why this matters: JSC on iOS has no native ES-module loader and its private loader SPI is absent
//  from the public SDK, so uBlock Origin Lite (a `"type":"module"` service worker) could not run at
//  all without this linker. These tests are the regression guard for that capability.
//

import XCTest
@testable import BrownBear

final class WebExtensionModuleWorkerTests: XCTestCase {

    struct ResourceMissing: Error { let name: String }

    private func bundledJS(_ name: String) throws -> String {
        let url = Bundle.main.url(forResource: name, withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: name, withExtension: "js")
        guard let url else { throw ResourceMissing(name: name) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func esmRuntimeSource() throws -> String {
        try bundledJS("brownbear-acorn") + "\n;\n" + bundledJS("brownbear-esm-linker")
    }

    /// Boot a module worker over a virtual package. `files` maps package-relative paths to source.
    /// `logs` collects every log line so fail-closed cases can be asserted.
    private func bootModuleWorker(entry: String,
                                  files: [String: String],
                                  logs: LogCollector) throws -> WebExtensionBackgroundContext {
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "ModuleTest",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.modtest.\(UUID().uuidString)"),
            logSink: { entry in logs.append(entry.message) })
        let source: @Sendable (String) -> Data? = { path in files[path]?.data(using: .utf8) }
        context.boot(runtimeJS: try bundledJS("brownbear-webext-background"),
                     backgroundSource: "",
                     manifestJSON: #"{"manifest_version":3,"name":"ModuleTest","version":"1.0","background":{"service_worker":"sw.js","type":"module"}}"#,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:],
                     moduleEntry: entry,
                     esmRuntimeJS: try esmRuntimeSource(),
                     moduleSource: source)
        return context
    }

    /// Thread-safe sink for the worker's log lines (logSink fires on the context's serial queue).
    final class LogCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    // MARK: - Happy path: a real module graph links and integrates with chrome.runtime

    func testModuleGraphLinksAndAnswersViaRuntimeMessage() async throws {
        let logs = LogCollector()
        let context = try bootModuleWorker(entry: "sw.js", files: [
            "sw.js": """
            import { computeAnswer } from './lib/math.js';
            import * as util from './lib/util.js';
            import defaultTag from './lib/tag.js';
            chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
              if (!msg || msg.q !== 'go') { return; }
              sendResponse({
                answer: computeAnswer(40, 2),
                tag: util.tag,
                def: defaultTag,
                meta: import.meta.url,
                hasSelf: self === globalThis
              });
            });
            """,
            "lib/math.js": "export function computeAnswer(a, b) { return a + b; }",
            "lib/util.js": "export const tag = 'linked';",
            "lib/tag.js": "export default 'default-export';"
        ], logs: logs)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["q": "go"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any],
                              "module worker should have registered a runtime.onMessage listener; logs: \(logs.all)")
        XCTAssertEqual(r["answer"] as? Int, 42)
        XCTAssertEqual(r["tag"] as? String, "linked")
        XCTAssertEqual(r["def"] as? String, "default-export")
        XCTAssertEqual(r["meta"] as? String, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/sw.js")
        XCTAssertEqual(r["hasSelf"] as? Bool, true)
        XCTAssertTrue(logs.all.allSatisfy { !$0.lowercased().contains("uncaught") }, "no uncaught errors: \(logs.all)")
    }

    // MARK: - Re-export chains and namespace re-export resolve correctly

    func testReExportChainResolves() async throws {
        let logs = LogCollector()
        let context = try bootModuleWorker(entry: "sw.js", files: [
            "sw.js": """
            import { value, NS } from './agg.js';
            chrome.runtime.onMessage.addListener(function (msg, s, send) {
              if (msg && msg.q === 'go') { send({ value: value, nested: NS.deep }); }
            });
            """,
            "agg.js": "export { value } from './leaf.js'; export * as NS from './nested.js';",
            "leaf.js": "export const value = 7;",
            "nested.js": "export const deep = 'D';"
        ], logs: logs)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["q": "go"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "logs: \(logs.all)")
        XCTAssertEqual(r["value"] as? Int, 7)
        XCTAssertEqual(r["nested"] as? String, "D")
    }

    // MARK: - Fail closed

    func testMissingModuleFailsClosedWithLog() async throws {
        let logs = LogCollector()
        let context = try bootModuleWorker(entry: "sw.js", files: [
            "sw.js": """
            import { gone } from './does-not-exist.js';
            chrome.runtime.onMessage.addListener(function (m, s, send) { send({ gone: gone }); });
            """
        ], logs: logs)
        defer { context.shutdown() }

        // No listener should have registered (the import threw before addListener ran).
        let response = await context.deliverRuntimeMessage(message: ["q": "go"], sender: [:])
        XCTAssertNil(response?["value"], "a worker whose graph failed to link must not answer messages")
        // Give the serial queue a beat to flush the exception log, then assert it was reported.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(logs.all.contains { $0.contains("module not found") || $0.lowercased().contains("uncaught") },
                      "expected a 'module not found' error in the log; got: \(logs.all)")
    }

    func testParseErrorFailsClosedWithLog() async throws {
        let logs = LogCollector()
        let context = try bootModuleWorker(entry: "sw.js", files: [
            "sw.js": "export const = ;"   // syntactically invalid
        ], logs: logs)
        defer { context.shutdown() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(logs.all.contains { $0.lowercased().contains("parse error") || $0.lowercased().contains("uncaught") },
                      "expected a parse error in the log; got: \(logs.all)")
    }
}
