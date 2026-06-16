//
//  WebExtensionBackgroundContext+ModuleWorker.swift
//  BrownBear
//
//  MV3 service workers may declare `"background": { "service_worker": "...", "type": "module" }`,
//  meaning the entry is an ES module with static `import`/`export` (e.g. uBlock Origin Lite). JSC on
//  iOS has no ES-module loader, and its native loader API (JSScript / moduleLoaderDelegate) is
//  private SPI absent from the public SDK — so we link the module graph in pure JS instead: acorn
//  parses each module and brownbear-esm-linker rewrites its import/export syntax into calls against
//  a synchronous registry, resolving sibling modules from the extension package on demand. This file
//  installs that resolver and kicks off the link; the heavy lifting is in the JS runtime.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// Evaluate the ESM linker runtime and run the module worker's graph. Called on the context's
    /// serial queue from `boot`. `moduleSource` reads a packaged module's bytes synchronously and
    /// path-contained (backed by the `WebExtensionStore` actor's `nonisolated fileSync`); a missing
    /// file returns JS `null` so the linker fails closed with "module not found" rather than crashing.
    func runModuleWorker(in context: JSContext,
                         esmRuntimeJS: String,
                         entryPaths: [String],
                         moduleSource: @escaping @Sendable (String) -> Data?) {
        // Returns the module's source, or nil → JS null/undefined so the linker fails closed with
        // "module not found" (matches the importScript bridge pattern in HeadlessScriptRunner).
        let resolveSource: @convention(block) (String) -> String? = { path in
            guard let data = moduleSource(path) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        context.setObject(resolveSource, forKeyedSubscript: "__bbModuleSource" as NSString)

        context.evaluateScript(esmRuntimeJS,
                               withSourceURL: URL(string: "brownbear://webext/\(extensionID)/esm-linker.js"))

        guard let runner = context.objectForKeyedSubscript("__bbRunModuleWorker"),
              !runner.isUndefined, !runner.isNull else {
            logSink(makeLog(.error, "module service worker: ESM linker runtime failed to load"))
            return
        }
        // The linker reports parse/resolution failures by throwing; the context's exceptionHandler
        // (installed in boot) logs them. A thrown error here leaves the worker un-booted, which is
        // the correct fail-closed outcome for an extension whose module graph can't be linked.
        //
        // A background PAGE can carry MORE THAN ONE `<script type="module">` (Sidebery: a locale dict
        // module BEFORE the real background.js). A browser runs each in document order, each its own
        // graph but sharing the global + the linker's module cache. Run them in order in this one context;
        // a throw in one entry is logged and cleared so the next still runs (independent module scripts).
        for entryPath in entryPaths {
            runner.call(withArguments: [entryPath])
            if let exception = context.exception {
                logSink(makeLog(.error, "background module \(entryPath) failed to link: \(exception)"))
                context.exception = nil
            }
        }
    }
}
