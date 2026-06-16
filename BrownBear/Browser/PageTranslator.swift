//
//  PageTranslator.swift
//  BrownBear
//
//  The native half of in-page translation. The page-side engine (brownbear-translate.js) collects the
//  page's translatable text nodes; this batches them, detects the source language, runs the batches through
//  a translation backend, and hands the results back for in-place replacement. Two backends per the product
//  decision: Apple's on-device Translation framework when available (iOS 18+, private, offline, free) and a
//  web service for older systems. The pure pieces here — batching, the "is translation even needed" decision,
//  and source-language detection (NaturalLanguage, on-device since iOS 12) — are unit-tested; the live
//  Translation-framework session and the web request are exercised on device.
//

import Foundation
import NaturalLanguage

/// One translatable unit the page engine handed us: a stable id (the tagged text node) + its source text.
struct TranslationUnit: Equatable {
    let id: String
    let text: String
}

/// A translation backend: turn source strings into target-language strings, order-preserving (result[i]
/// is the translation of texts[i]). `source` is a BCP-47 code or nil to let the backend auto-detect.
protocol PageTranslating: Sendable {
    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String]
}

enum PageTranslator {

    /// Group units into batches each under `maxChars` of source text, so a backend request (Apple session or
    /// one web call) carries a bounded payload while still amortising overhead across many short nodes. A
    /// single unit longer than the budget becomes its own batch (never split mid-node — a node is the atom of
    /// in-place replacement). Order is preserved so streamed results map back to the page in document order.
    static func batches(_ units: [TranslationUnit], maxChars: Int = 4000) -> [[TranslationUnit]] {
        guard maxChars > 0 else { return units.map { [$0] } }
        var result: [[TranslationUnit]] = []
        var current: [TranslationUnit] = []
        var currentChars = 0
        for unit in units {
            let len = unit.text.count
            if !current.isEmpty, currentChars + len > maxChars {
                result.append(current)
                current = []
                currentChars = 0
            }
            current.append(unit)
            currentChars += len
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The two-letter language of `code` (BCP-47 or a bare code), lowercased — so "en-US", "EN", and "en"
    /// all compare as "en". nil for an empty/unknown code.
    static func primaryLanguage(of code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return base.isEmpty ? nil : base.lowercased()
    }

    /// Whether translating `source` into `target` is worth doing: only when we know the source AND it differs
    /// from the target language. An unknown source (nil) returns true — let the backend try and auto-detect
    /// rather than silently skip — while a source that already matches the target is a no-op.
    static func needsTranslation(source: String?, target: String) -> Bool {
        guard let src = primaryLanguage(of: source) else { return true }
        guard let dst = primaryLanguage(of: target) else { return true }
        return src != dst
    }

    /// Detect the dominant language of a page sample (the first N collected nodes joined) on-device via
    /// NaturalLanguage. Returns a BCP-47 primary code ("en", "ja", "de") or nil when undetermined — used to
    /// label the source and to short-circuit when the page is already in the user's language.
    static func detectLanguage(of sample: String) -> String? {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }   // too little signal → don't guess
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        return language.rawValue   // NLLanguage.rawValue is the BCP-47 code, e.g. "en", "zh-Hans"
    }

    /// Build the language sample the detector should see from the collected units: the first units' text up
    /// to a character cap, so detection is fast and dominated by real prose rather than scanning a whole page.
    static func languageSample(from units: [TranslationUnit], maxChars: Int = 1200) -> String {
        var sample = ""
        for unit in units {
            sample += unit.text + " "
            if sample.count >= maxChars { break }
        }
        return sample
    }
}
