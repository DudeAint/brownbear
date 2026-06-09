//
//  WebExtensionPlatformTests.swift
//  BrownBearTests
//
//  chrome.i18n.detectLanguage maps NLLanguageRecognizer output to Chrome's CLD shape
//  ({isReliable, languages:[{language, percentage}]}, sorted by confidence). These lock in the shape,
//  the sort order, and the empty-input contract.
//

import XCTest
@testable import BrownBear

final class WebExtensionPlatformTests: XCTestCase {

    func testDetectEnglish() {
        let r = WebExtensionBackgroundContext.detectLanguages(
            in: "The quick brown fox jumps over the lazy dog. This is clearly an English sentence.")
        let languages = try? XCTUnwrap(r["languages"] as? [[String: Any]])
        XCTAssertNotNil(languages)
        XCTAssertFalse((languages ?? []).isEmpty, "a clear English sentence must yield at least one language")
        XCTAssertEqual((languages?.first?["language"] as? String), "en", "English should be the top hypothesis")
        // Percentages are integers 0...100.
        for entry in languages ?? [] {
            let pct = entry["percentage"] as? Int
            XCTAssertNotNil(pct)
            XCTAssert((0...100).contains(pct ?? -1), "percentage out of range: \(String(describing: pct))")
        }
        XCTAssertEqual(r["isReliable"] as? Bool, true, "a clear sentence should be reliable")
    }

    func testDetectSortedByConfidenceDescending() {
        let r = WebExtensionBackgroundContext.detectLanguages(
            in: "Bonjour, ceci est une phrase clairement écrite en français pour la détection.")
        let languages = (r["languages"] as? [[String: Any]]) ?? []
        let pcts = languages.compactMap { $0["percentage"] as? Int }
        XCTAssertEqual(pcts, pcts.sorted(by: >), "languages must be sorted by confidence, descending")
    }

    func testEmptyInputIsNotReliable() {
        for text in ["", "   ", "\n\t "] {
            let r = WebExtensionBackgroundContext.detectLanguages(in: text)
            XCTAssertEqual(r["isReliable"] as? Bool, false, "empty/whitespace input is not reliable: \(text.debugDescription)")
            XCTAssertEqual((r["languages"] as? [[String: Any]])?.count, 0, "no languages for empty input")
        }
    }
}
