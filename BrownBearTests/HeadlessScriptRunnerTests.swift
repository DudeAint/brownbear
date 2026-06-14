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

    func testBulkValueAPIsAndChangeListener() async throws {
        let (runner, valueStore) = makeRunner()
        let bulk = """
        // ==UserScript==
        // @name        Bulk
        // @crontab     * * * * *
        // ==/UserScript==
        GM_setValues({ a: 1, b: 'two' });
        var got = GM_getValues(['a', 'b', 'missing']);
        GM_setValue('gotA', got.a);
        GM_setValue('gotB', got.b);
        GM_setValue('gotMissingType', typeof got.missing);
        var fires = 0;
        var id = GM_addValueChangeListener('watched', function (key, oldV, newV) { fires = newV; });
        GM_setValue('watched', 42);
        GM_setValue('firesSeen', fires);
        GM_removeValueChangeListener(id);
        GM_setValue('watched', 99);
        GM_setValue('firesAfterRemove', fires);
        GM_deleteValues(['a']);
        GM_setValue('aAfterDelete', GM_getValue('a', 'gone'));
        """
        let userScript = try UserScript.make(from: bulk)
        let (outcome, _) = await runner.run(userScript, deadline: Date().addingTimeInterval(10))
        XCTAssertTrue(outcome.succeeded, "error: \(outcome.error ?? "")")
        let id = userScript.id
        let gotA = await valueStore.value(scriptID: id, key: "gotA")
        let gotB = await valueStore.value(scriptID: id, key: "gotB")
        let gotMissing = await valueStore.value(scriptID: id, key: "gotMissingType")
        let firesSeen = await valueStore.value(scriptID: id, key: "firesSeen")
        let firesAfterRemove = await valueStore.value(scriptID: id, key: "firesAfterRemove")
        let aAfterDelete = await valueStore.value(scriptID: id, key: "aAfterDelete")
        XCTAssertEqual(gotA, "1", "GM_getValues read a bulk-set numeric value")
        XCTAssertEqual(gotB, "\"two\"", "GM_getValues read a bulk-set string value")
        XCTAssertEqual(gotMissing, "\"undefined\"", "a missing key is absent from GM_getValues")
        XCTAssertEqual(firesSeen, "42", "GM_addValueChangeListener fired with the new value")
        XCTAssertEqual(firesAfterRemove, "42", "a removed listener no longer fires (stays at 42)")
        XCTAssertEqual(aAfterDelete, "\"gone\"", "GM_deleteValues removed the key")
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
