//
//  PageTranslatorTests.swift
//  BrownBearTests
//
//  The pure native core of in-page translation: batching the collected text nodes under a character budget
//  (without ever splitting a node), the BCP-47 primary-language normalization + "is translation needed"
//  decision (skip when the page is already in the target language), the language sample builder, and the
//  on-device NaturalLanguage source detection. The live Translation-framework session + web request are
//  device-exercised; this locks the logic that decides what to send and whether to bother.
//

import XCTest
@testable import BrownBear

final class PageTranslatorTests: XCTestCase {

    private func u(_ id: String, _ text: String) -> TranslationUnit { TranslationUnit(id: id, text: text) }

    // MARK: - Batching

    func testBatchesGroupUnderCharBudget() {
        let units = [u("a", "12345"), u("b", "12345"), u("c", "12345")]   // 5 chars each
        let batches = PageTranslator.batches(units, maxChars: 12)
        XCTAssertEqual(batches.count, 2, "5+5 fits one batch (10≤12); the third (15>12) starts a new batch")
        XCTAssertEqual(batches[0].map(\.id), ["a", "b"])
        XCTAssertEqual(batches[1].map(\.id), ["c"])
    }

    func testBatchesNeverSplitASingleOversizeNode() {
        let units = [u("big", String(repeating: "x", count: 100)), u("small", "y")]
        let batches = PageTranslator.batches(units, maxChars: 10)
        XCTAssertEqual(batches.count, 2, "a node larger than the budget becomes its own batch (never split)")
        XCTAssertEqual(batches[0].map(\.id), ["big"])
        XCTAssertEqual(batches[1].map(\.id), ["small"])
    }

    func testBatchesPreserveOrder() {
        let units = (0..<10).map { u("n\($0)", "word") }   // 4 chars each
        let flat = PageTranslator.batches(units, maxChars: 9).flatMap { $0 }   // 2 per batch
        XCTAssertEqual(flat.map(\.id), units.map(\.id), "document order is preserved across batches")
    }

    func testBatchesEmptyInput() {
        XCTAssertEqual(PageTranslator.batches([], maxChars: 100).count, 0)
    }

    // MARK: - Language normalization + decision

    func testPrimaryLanguageNormalizes() {
        XCTAssertEqual(PageTranslator.primaryLanguage(of: "en-US"), "en")
        XCTAssertEqual(PageTranslator.primaryLanguage(of: "EN"), "en")
        XCTAssertEqual(PageTranslator.primaryLanguage(of: "zh_Hans"), "zh")
        XCTAssertNil(PageTranslator.primaryLanguage(of: ""))
        XCTAssertNil(PageTranslator.primaryLanguage(of: nil))
    }

    func testNeedsTranslationSkipsSameLanguage() {
        XCTAssertFalse(PageTranslator.needsTranslation(source: "en", target: "en-US"), "already in target → skip")
        XCTAssertFalse(PageTranslator.needsTranslation(source: "en-GB", target: "en"), "region variants still match")
        XCTAssertTrue(PageTranslator.needsTranslation(source: "ja", target: "en"), "different language → translate")
    }

    func testNeedsTranslationWhenSourceUnknown() {
        XCTAssertTrue(PageTranslator.needsTranslation(source: nil, target: "en"),
                      "unknown source → attempt (let the backend auto-detect) rather than silently skip")
    }

    // MARK: - Language sample + on-device detection

    func testLanguageSampleStopsAtBudget() {
        let units = (0..<100).map { u("n\($0)", "abcdefghij") }   // 10 chars each
        let sample = PageTranslator.languageSample(from: units, maxChars: 50)
        XCTAssertLessThan(sample.count, 100, "the sample is bounded, not the whole page")
        XCTAssertTrue(sample.hasPrefix("abcdefghij"), "it starts from the first nodes (real prose)")
    }

    func testDetectLanguageIdentifiesEnglishAndJapanese() {
        // NaturalLanguage runs on-device in the test host. Use clearly-monolingual samples.
        XCTAssertEqual(PageTranslator.detectLanguage(of: "The quick brown fox jumps over the lazy dog every morning."), "en")
        XCTAssertEqual(PageTranslator.detectLanguage(of: "今日はとても良い天気ですので、公園を散歩しましょう。"), "ja")
    }

    func testDetectLanguageReturnsNilOnTooLittleSignal() {
        XCTAssertNil(PageTranslator.detectLanguage(of: "ok"), "too few characters to guess a language")
        XCTAssertNil(PageTranslator.detectLanguage(of: "   "), "whitespace only → nil")
    }
}
