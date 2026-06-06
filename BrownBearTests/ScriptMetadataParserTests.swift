//
//  ScriptMetadataParserTests.swift
//  BrownBearTests
//
//  Table-driven tests for the userscript metadata parser, including malformed input.
//

import XCTest
@testable import BrownBear

final class ScriptMetadataParserTests: XCTestCase {

    private let parser = ScriptMetadataParser()

    private let fullScript = """
    // ==UserScript==
    // @name         Example Script
    // @name:fr      Script Exemple
    // @namespace    https://brownbear.app
    // @version      1.2.3
    // @description  Does a thing
    // @author       Ada
    // @match        *://*.example.com/*
    // @match        https://test.org/*
    // @include      /^https:\\/\\/inc\\./
    // @exclude      *://*.example.com/private/*
    // @grant        GM_setValue
    // @grant        GM_xmlhttpRequest
    // @connect      api.example.com
    // @require      https://cdn.example.com/lib.js
    // @resource     css https://cdn.example.com/style.css
    // @run-at       document-start
    // @noframes
    // ==/UserScript==
    console.log("body");
    """

    func testParsesAllFields() throws {
        let meta = try parser.parse(fullScript)
        XCTAssertEqual(meta.name, "Example Script")
        XCTAssertEqual(meta.localizedNames["fr"], "Script Exemple")
        XCTAssertEqual(meta.namespace, "https://brownbear.app")
        XCTAssertEqual(meta.version, "1.2.3")
        XCTAssertEqual(meta.descriptionText, "Does a thing")
        XCTAssertEqual(meta.author, "Ada")
        XCTAssertEqual(meta.matches, ["*://*.example.com/*", "https://test.org/*"])
        XCTAssertEqual(meta.includes, ["/^https:\\/\\/inc\\./"])
        XCTAssertEqual(meta.excludes, ["*://*.example.com/private/*"])
        XCTAssertEqual(meta.grants.sorted(), ["GM_setValue", "GM_xmlhttpRequest"])
        XCTAssertEqual(meta.connects, ["api.example.com"])
        XCTAssertEqual(meta.requires, ["https://cdn.example.com/lib.js"])
        XCTAssertEqual(meta.resources["css"], "https://cdn.example.com/style.css")
        XCTAssertEqual(meta.runAt, .documentStart)
        XCTAssertTrue(meta.noFrames)
        XCTAssertFalse(meta.metadataBlock.isEmpty)
    }

    func testRunAtDefaultsToDocumentEnd() throws {
        let script = "// ==UserScript==\n// @name X\n// @match *://*/*\n// ==/UserScript==\n"
        let meta = try parser.parse(script)
        XCTAssertEqual(meta.runAt, .documentEnd)
    }

    func testGrantNone() throws {
        let script = "// ==UserScript==\n// @name X\n// @grant none\n// ==/UserScript==\n"
        let meta = try parser.parse(script)
        XCTAssertTrue(meta.grantsNone)
        XCTAssertTrue(meta.effectiveGrants.isEmpty)
    }

    func testMissingBlockThrows() {
        XCTAssertThrowsError(try parser.parse("console.log('no header')"))
    }

    func testMissingNameThrows() {
        let script = "// ==UserScript==\n// @match *://*/*\n// ==/UserScript==\n"
        XCTAssertThrowsError(try parser.parse(script))
    }

    func testCRLFLineEndingsParse() throws {
        let script = "// ==UserScript==\r\n// @name CRLF\r\n// @match *://*/*\r\n// ==/UserScript==\r\n"
        let meta = try parser.parse(script)
        XCTAssertEqual(meta.name, "CRLF")
        XCTAssertEqual(meta.matches, ["*://*/*"])
    }

    func testParsesCrontabAndBackground() throws {
        let script = """
        // ==UserScript==
        // @name      BG
        // @background
        // @crontab   */5 * * * *
        // @crontab   0 9 * * 1
        // ==/UserScript==
        """
        let meta = try parser.parse(script)
        XCTAssertTrue(meta.isBackground)
        XCTAssertEqual(meta.crontabs, ["*/5 * * * *", "0 9 * * 1"])
        XCTAssertTrue(meta.runsInBackground)
    }

    func testUnknownKeysIgnored() throws {
        let script = "// ==UserScript==\n// @name X\n// @unknownkey whatever\n// @match *://*/*\n// ==/UserScript==\n"
        let meta = try parser.parse(script)
        XCTAssertEqual(meta.name, "X")
    }
}
