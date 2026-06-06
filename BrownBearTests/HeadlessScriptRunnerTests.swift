//
//  HeadlessScriptRunnerTests.swift
//  BrownBearTests
//
//  End-to-end tests for the background JSContext runner: it should execute a script's body,
//  expose a working GM storage surface (read snapshot, write-back), capture console output, and
//  surface JS errors — all with no web view.
//

import XCTest
@testable import BrownBear

final class HeadlessScriptRunnerTests: XCTestCase {

    private func makeRunner() -> (HeadlessScriptRunner, GMValueStore) {
        let valueStore = GMValueStore(suiteName: "brownbear.test.\(UUID().uuidString)")
        return (HeadlessScriptRunner(valueStore: valueStore), valueStore)
    }

    private let script = """
    // ==UserScript==
    // @name        Counter
    // @crontab     * * * * *
    // ==/UserScript==
    var n = GM_getValue('count', 0) + 1;
    GM_setValue('count', n);
    console.log('ran', n);
    """

    func testRunsPersistsValueAndCapturesLog() async throws {
        let (runner, valueStore) = makeRunner()
        let userScript = try UserScript.make(from: script)

        let (outcome, logs) = await runner.run(userScript, deadline: Date().addingTimeInterval(10))
        XCTAssertTrue(outcome.succeeded, "error: \(outcome.error ?? "")")

        let stored = await valueStore.value(scriptID: userScript.id, key: "count")
        XCTAssertEqual(stored, "1")
        XCTAssertTrue(logs.contains { $0.message.contains("ran") && $0.message.contains("1") })
    }

    func testStateCarriesAcrossRuns() async throws {
        let (runner, valueStore) = makeRunner()
        let userScript = try UserScript.make(from: script)

        _ = await runner.run(userScript, deadline: Date().addingTimeInterval(10))
        _ = await runner.run(userScript, deadline: Date().addingTimeInterval(10))

        let stored = await valueStore.value(scriptID: userScript.id, key: "count")
        XCTAssertEqual(stored, "2", "GM value snapshot should carry across background runs")
    }

    func testSurfacesJSError() async throws {
        let (runner, _) = makeRunner()
        let bad = """
        // ==UserScript==
        // @name Boom
        // @background
        // ==/UserScript==
        throw new Error('kaboom');
        """
        let userScript = try UserScript.make(from: bad)
        let (outcome, _) = await runner.run(userScript, deadline: Date().addingTimeInterval(5))
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.error?.contains("kaboom") ?? false)
    }

    func testValuesAreScriptNamespaced() async throws {
        let (runner, valueStore) = makeRunner()
        let scriptA = try UserScript.make(from: script)
        let scriptB = try UserScript.make(from: script)   // distinct id

        _ = await runner.run(scriptA, deadline: Date().addingTimeInterval(10))
        _ = await runner.run(scriptB, deadline: Date().addingTimeInterval(10))

        let a = await valueStore.value(scriptID: scriptA.id, key: "count")
        let b = await valueStore.value(scriptID: scriptB.id, key: "count")
        XCTAssertEqual(a, "1")
        XCTAssertEqual(b, "1") // each counts independently in its own namespace
    }
}
