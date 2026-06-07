//
//  HeadlessEnvironmentTests.swift
//  BrownBearTests
//
//  Covers the device-derived values injected into headless JS contexts for the navigator polyfill.
//  Userscripts sniff the UA for "Safari"/"Mobile"/"iPhone"; if any token is missing or the version is
//  malformed, those checks misfire — so the shape is asserted, not just non-emptiness.
//

import XCTest
@testable import BrownBear

final class HeadlessEnvironmentTests: XCTestCase {

    func testUserAgentCarriesTheTokensScriptsSniffFor() {
        let ua = HeadlessEnvironment.userAgent
        XCTAssertTrue(ua.hasPrefix("Mozilla/5.0 "), "must start with the standard Mozilla token: \(ua)")
        for token in ["iPhone", "CPU iPhone OS", "AppleWebKit/605.1.15", "like Gecko",
                      "Version/", "Mobile/15E148", "Safari/604.1"] {
            XCTAssertTrue(ua.contains(token), "UA missing \(token): \(ua)")
        }
    }

    func testUserAgentEmbedsTheRunningOSVersion() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let ua = HeadlessEnvironment.userAgent
        // Both the platform ("CPU iPhone OS <major>_") and the Safari ("Version/<major>.") tokens carry
        // the live major version, so the UA never reports a stale OS.
        XCTAssertTrue(ua.contains("CPU iPhone OS \(major)_"), "platform version absent: \(ua)")
        XCTAssertTrue(ua.contains("Version/\(major)."), "Safari version absent: \(ua)")
    }

    func testLanguageIsANonEmptyBCP47Tag() {
        let lang = HeadlessEnvironment.language
        XCTAssertFalse(lang.isEmpty)
        // A BCP-47 primary subtag is letters; reject obviously broken values like a bare "_" locale.
        XCTAssertTrue(lang.first?.isLetter == true, "language not a language tag: \(lang)")
    }
}
