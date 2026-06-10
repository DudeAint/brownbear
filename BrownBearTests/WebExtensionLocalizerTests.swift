//
//  WebExtensionLocalizerTests.swift
//  BrownBearTests
//
//  Table-driven coverage for the Chrome i18n `__MSG_*__` substitution that fixes the user-reported
//  symptom of localized extensions showing up as the literal "__MSG_appName__" / "__MSG_title__".
//  Tests the pure substitution against a known message map (no disk), including predefined `@@`
//  messages, case-insensitive keys, multiple/adjacent placeholders, malformed tokens, and the
//  humanized fallback for a missing key.
//

import XCTest
@testable import BrownBear

final class WebExtensionLocalizerTests: XCTestCase {

    private let extID = "abcdefghijklmnopabcdefghijklmnop"   // 32 chars a–p

    private func resolve(_ raw: String,
                         messages: [String: String] = [:],
                         locale: String? = "en") -> String {
        WebExtensionLocalizer.substitute(raw, extensionID: extID, defaultLocale: locale, messages: messages)
    }

    func testResolvesSinglePlaceholder() {
        XCTAssertEqual(resolve("__MSG_appName__", messages: ["appname": "ScriptCat"]), "ScriptCat")
    }

    func testKeyLookupIsCaseInsensitive() {
        // Manifest authored with mixed case; messages.json keys are stored lowercased by the loader.
        XCTAssertEqual(resolve("__MSG_AppName__", messages: ["appname": "ScriptCat"]), "ScriptCat")
        XCTAssertEqual(resolve("__MSG_APPNAME__", messages: ["appname": "ScriptCat"]), "ScriptCat")
    }

    func testEmbeddedAndAdjacentPlaceholders() {
        let messages = ["brand": "Brown", "bear": "Bear"]
        XCTAssertEqual(resolve("__MSG_brand____MSG_bear__", messages: messages), "BrownBear")
        XCTAssertEqual(resolve("[__MSG_brand__] tool", messages: messages), "[Brown] tool")
    }

    func testTextWithoutPlaceholderIsUnchanged() {
        XCTAssertEqual(resolve("Plain Name", messages: ["appname": "X"]), "Plain Name")
    }

    func testPredefinedExtensionIDMessage() {
        XCTAssertEqual(resolve("id:__MSG_@@extension_id__"), "id:\(extID)")
    }

    func testPredefinedUILocaleMessage() {
        XCTAssertEqual(resolve("__MSG_@@ui_locale__", locale: "fr"), "fr")
    }

    func testBidiDirectionForRTLLocale() {
        XCTAssertEqual(resolve("__MSG_@@bidi_dir__", locale: "ar"), "rtl")
        XCTAssertEqual(resolve("__MSG_@@bidi_dir__", locale: "he_IL"), "rtl")
        XCTAssertEqual(resolve("__MSG_@@bidi_dir__", locale: "en"), "ltr")
    }

    func testMissingKeyFallsBackToHumanizedLabel() {
        // No message for the key, and no raw "__MSG_…__" token should ever leak to the UI.
        let out = resolve("__MSG_appName__")
        XCTAssertEqual(out, "App Name")
        XCTAssertFalse(out.contains("__MSG_"))
    }

    func testMissingKeyWithUnderscoresHumanizes() {
        XCTAssertEqual(resolve("__MSG_app_title__"), "App Title")
    }

    func testMalformedTokenLeftIntact() {
        // No closing "__": not a placeholder, emitted verbatim.
        XCTAssertEqual(resolve("__MSG_unterminated", messages: [:]), "__MSG_unterminated")
        // Empty key ("__MSG____") is not a valid placeholder.
        XCTAssertEqual(resolve("__MSG____", messages: [:]), "__MSG____")
    }

    func testRealWorldScriptCatStyleName() {
        // The reported case: name is exactly the placeholder, default locale present.
        let resolved = resolve("__MSG_scriptcat__", messages: ["scriptcat": "ScriptCat"])
        XCTAssertEqual(resolved, "ScriptCat")
    }

    /// chrome.i18n NAMED placeholders are surfaced to the shims so getMessage can resolve `$version$`
    /// (Tampermonkey's options/popup showed the literal token). The map is messageKey → name.lower →
    /// content; messages WITHOUT placeholders are omitted; non-dict / contentless entries are skipped.
    func testExtractsNamedPlaceholders() {
        let json: [String: Any] = [
            "update": ["message": "$NAME$ $VERSION$ is available",
                       "placeholders": ["name": ["content": "$1"], "version": ["content": "$2"]]],
            "plain": ["message": "no placeholders here"],
            "weird": ["message": "x", "placeholders": ["bad": "not-a-dict", "empty": [:]]]
        ]
        let out = WebExtensionLocalizer.extractPlaceholders(fromMessagesJSON: json)
        XCTAssertEqual(out["update"]?["name"], "$1")
        XCTAssertEqual(out["update"]?["version"], "$2")
        XCTAssertNil(out["plain"], "a message without placeholders is omitted")
        XCTAssertNil(out["weird"], "non-dict / contentless placeholder entries leave no usable map")
    }
}
