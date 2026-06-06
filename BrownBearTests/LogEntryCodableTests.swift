//
//  LogEntryCodableTests.swift
//  BrownBearTests
//
//  Guards the LogEntry `source` migration AGAINST THE PRODUCTION CODERS. LogStore persists logs.json
//  with JSONEncoder/Decoder.brownBear (dateEncodingStrategy = .iso8601), so the legacy on-disk shape
//  has `createdAt` as an ISO8601 *string* and no `source` key. These tests use those same coders and
//  fixtures so a regression in the date strategy — or any drift between LogEntry's custom init(from:)
//  and the brownBear decoder — is caught, instead of validating a decode path the app never uses.
//

import XCTest
@testable import BrownBear

final class LogEntryCodableTests: XCTestCase {

    private let isoString = "2023-11-14T22:13:20Z"
    private let isoDate = Date(timeIntervalSince1970: 1_700_000_000)   // == 2023-11-14T22:13:20Z

    func testLegacyEntryWithoutSourceDecodesAsUserscript() throws {
        // An entry written by a build that predates `source` — note createdAt is an ISO8601 STRING.
        let json = """
        {"id":"\(UUID().uuidString)","scriptName":"Old Script","level":"info",
         "message":"hello","createdAt":"\(isoString)","context":"foreground"}
        """.data(using: .utf8)!
        let entry = try JSONDecoder.brownBear.decode(LogEntry.self, from: json)
        XCTAssertEqual(entry.source, .userscript)
        XCTAssertEqual(entry.message, "hello")
        XCTAssertEqual(entry.createdAt, isoDate)
        XCTAssertNil(entry.scriptID)
    }

    func testExplicitNullSourceDecodesAsUserscript() throws {
        let json = """
        {"id":"\(UUID().uuidString)","scriptName":"X","level":"warn",
         "message":"m","createdAt":"\(isoString)","context":"background","source":null}
        """.data(using: .utf8)!
        let entry = try JSONDecoder.brownBear.decode(LogEntry.self, from: json)
        XCTAssertEqual(entry.source, .userscript)
    }

    func testLegacyArrayDecodesWithoutThrowing() throws {
        // The LogStore persists an array; a mix of legacy entries must all load (not throw).
        let json = """
        [{"id":"\(UUID().uuidString)","scriptName":"A","level":"warn","message":"a",
          "createdAt":"\(isoString)","context":"background"},
         {"id":"\(UUID().uuidString)","scriptName":"B","level":"error","message":"b",
          "createdAt":"\(isoString)","context":"foreground"}]
        """.data(using: .utf8)!
        let entries = try JSONDecoder.brownBear.decode([LogEntry].self, from: json)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.source == .userscript })
    }

    func testRoundTripThroughProductionCodersPreservesSourceAndDate() throws {
        // Whole-second date so the .iso8601 strategy round-trips exactly.
        let entry = LogEntry(scriptID: nil, scriptName: "Ext", level: .error, message: "boom",
                             createdAt: isoDate, context: .background, source: .engine)
        let data = try JSONEncoder.brownBear.encode(entry)
        let decoded = try JSONDecoder.brownBear.decode(LogEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.source, .engine)
    }
}
