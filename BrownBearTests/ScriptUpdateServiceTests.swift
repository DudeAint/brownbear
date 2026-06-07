//
//  ScriptUpdateServiceTests.swift
//  BrownBearTests
//
//  Pure-logic tests for the userscript update version comparison: a remote @version is "newer" only
//  when it strictly exceeds the local one, component by component, with fail-closed handling of
//  missing/garbage versions (we never replace a script on a bad fetch).
//

import XCTest
@testable import BrownBear

final class ScriptUpdateServiceTests: XCTestCase {

    func testNewerVersionsDetected() {
        XCTAssertTrue(ScriptUpdateService.isVersion("1.2.1", newerThan: "1.2.0"))
        XCTAssertTrue(ScriptUpdateService.isVersion("1.2.10", newerThan: "1.2.9"))   // numeric, not lexical
        XCTAssertTrue(ScriptUpdateService.isVersion("2.0", newerThan: "1.9.9"))
        XCTAssertTrue(ScriptUpdateService.isVersion("1.0.1", newerThan: "1.0"))      // extra component
    }

    func testSameOrOlderIsNotNewer() {
        XCTAssertFalse(ScriptUpdateService.isVersion("1.2.0", newerThan: "1.2.0"))
        XCTAssertFalse(ScriptUpdateService.isVersion("1.2.0", newerThan: "1.2.0.0"))  // trailing zeros equal
        XCTAssertFalse(ScriptUpdateService.isVersion("1.0", newerThan: "1.0.1"))
        XCTAssertFalse(ScriptUpdateService.isVersion("0.9", newerThan: "1.0"))
    }

    func testMissingOrGarbageRemoteFailsClosed() {
        XCTAssertFalse(ScriptUpdateService.isVersion(nil, newerThan: "1.0"))
        XCTAssertFalse(ScriptUpdateService.isVersion("", newerThan: "1.0"))
        // Unparseable remote → all-zero components → not newer than 1.0.
        XCTAssertFalse(ScriptUpdateService.isVersion("abc", newerThan: "1.0"))
    }

    func testNewInstallWithNoLocalVersion() {
        // No local version is treated as 0, so any real remote version is an update.
        XCTAssertTrue(ScriptUpdateService.isVersion("1.0", newerThan: nil))
        XCTAssertFalse(ScriptUpdateService.isVersion("0.0", newerThan: nil))
    }
}
