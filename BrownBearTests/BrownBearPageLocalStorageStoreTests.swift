//
//  BrownBearPageLocalStorageStoreTests.swift
//  BrownBearTests
//
//  The per-extension persistence behind an extension page's window.localStorage (the chrome-extension://
//  origin has no real DOM storage). Covers a round-trip, the security-critical property that one
//  extension can never read another's localStorage, clear-on-uninstall, and the traversal-safe filename
//  sanitizer. Determinism: the store writes/clears on a private serial queue, so each mutation is followed
//  by waitForPendingWrites() (a sync barrier) instead of polling, and setUp clears the test ids up front.
//

import XCTest
@testable import BrownBear

final class BrownBearPageLocalStorageStoreTests: XCTestCase {

    private let store = BrownBearPageLocalStorageStore.shared
    private let idA = "unit-test-extls-A"
    private let idB = "unit-test-extls-B"

    override func setUp() {
        super.setUp()
        store.clear(extensionID: idA); store.clear(extensionID: idB)
        store.waitForPendingWrites()
    }

    override func tearDown() {
        store.clear(extensionID: idA); store.clear(extensionID: idB)
        store.waitForPendingWrites()
        super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let json = #"{"theme":"dark","firstSynchronized":"1","count":"7"}"#
        store.save(json, extensionID: idA)
        store.waitForPendingWrites()
        XCTAssertEqual(store.load(extensionID: idA), json, "the page's localStorage snapshot persists verbatim")
    }

    func testAbsentSnapshotIsNil() {
        XCTAssertNil(store.load(extensionID: "never-written-ext"), "no snapshot → nil (page seeds empty)")
    }

    func testOverwriteReplacesSnapshot() {
        store.save(#"{"a":"1"}"#, extensionID: idA)
        store.waitForPendingWrites()
        store.save(#"{"a":"2","b":"3"}"#, extensionID: idA)
        store.waitForPendingWrites()
        XCTAssertEqual(store.load(extensionID: idA), #"{"a":"2","b":"3"}"#, "the latest snapshot wins")
    }

    func testNamespacesAreIsolatedPerExtension() {
        // Security (CLAUDE.md §5): extension A must never read extension B's localStorage.
        store.save(#"{"secret":"A"}"#, extensionID: idA)
        store.save(#"{"secret":"B"}"#, extensionID: idB)
        store.waitForPendingWrites()
        XCTAssertEqual(store.load(extensionID: idA), #"{"secret":"A"}"#)
        XCTAssertEqual(store.load(extensionID: idB), #"{"secret":"B"}"#)
        XCTAssertNotEqual(store.load(extensionID: idA), store.load(extensionID: idB))
    }

    func testClearRemovesSnapshot() {
        store.save(#"{"x":"1"}"#, extensionID: idA)
        store.waitForPendingWrites()
        store.clear(extensionID: idA)
        store.waitForPendingWrites()
        XCTAssertNil(store.load(extensionID: idA), "clear() (e.g. on uninstall) removes the snapshot")
    }

    func testFilenameSanitizerStripsTraversal() {
        // A hostile id can never escape the extls directory: only [A-Za-z0-9_-] survive.
        XCTAssertEqual(BrownBearPageLocalStorageStore.sanitizedFilename("../../etc/passwd"), "______etc_passwd")
        XCTAssertEqual(BrownBearPageLocalStorageStore.sanitizedFilename("abc-DEF_123"), "abc-DEF_123")
        XCTAssertEqual(BrownBearPageLocalStorageStore.sanitizedFilename(""), "default")
    }

    func testDistinctSanitizedIdsDoNotCollide() {
        // Two different real extension ids must map to different files.
        let a = BrownBearPageLocalStorageStore.sanitizedFilename("dhdgffkkebhmkfjojejmpbldmpobfkfo")
        let b = BrownBearPageLocalStorageStore.sanitizedFilename("ipdaaapoagjdimoilolljnbbpoldomcc")
        XCTAssertNotEqual(a, b)
    }
}
