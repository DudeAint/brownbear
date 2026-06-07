//
//  JSONSanitizeTests.swift
//  BrownBearTests
//
//  Regression coverage for the "Invalid number value (NaN) in JSON write" crash: a JS message / value
//  carrying NaN or ±Infinity must not reach JSONSerialization (which throws an uncatchable Obj-C
//  exception). JSONSanitize replaces non-finite numbers with null, recursively, and fails closed.
//

import XCTest
@testable import BrownBear

final class JSONSanitizeTests: XCTestCase {

    func testTopLevelNaNDictDoesNotThrowAndBecomesNull() {
        let out = JSONSanitize.string(["x": Double.nan, "y": 1.5])
        // The crash was here (JSONSerialization on NaN); assert we got valid JSON instead.
        let parsed = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?["x"] is NSNull)
        XCTAssertEqual(parsed?["y"] as? Double, 1.5)
    }

    func testInfinityInNestedArrayBecomesNull() {
        let value: [String: Any] = ["a": [1, Double.infinity, 3], "b": ["c": -Double.infinity]]
        let parsed = (try? JSONSerialization.jsonObject(with: Data(JSONSanitize.string(value).utf8))) as? [String: Any]
        let a = parsed?["a"] as? [Any]
        XCTAssertEqual(a?.count, 3)
        XCTAssertTrue(a?[1] is NSNull)
        XCTAssertTrue((parsed?["b"] as? [String: Any])?["c"] is NSNull)
    }

    func testFiniteValuesAndBoolsArePreserved() {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(
            JSONSanitize.string(["i": 42, "d": 3.25, "flag": true, "s": "ok"]).utf8))) as? [String: Any]
        XCTAssertEqual(parsed?["i"] as? Int, 42)
        XCTAssertEqual(parsed?["d"] as? Double, 3.25)
        XCTAssertEqual(parsed?["flag"] as? Bool, true)
        XCTAssertEqual(parsed?["s"] as? String, "ok")
    }

    func testBareFragmentsRoundTrip() {
        XCTAssertEqual(JSONSanitize.string("hello"), "\"hello\"")
        XCTAssertEqual(JSONSanitize.string(7), "7")
        XCTAssertEqual(JSONSanitize.string(Double.nan), "null")
    }

    func testNonSerializableFailsClosedToNull() {
        XCTAssertEqual(JSONSanitize.string(Data([1, 2, 3])), "null")
    }
}
