//
//  WebExtensionActionStateTests.swift
//  BrownBearTests
//
//  Verifies chrome.action state layering: manifest base → default layer → per-tab override, the
//  "clear" semantics of empty values, popup vs onClicked resolution, tab/extension forgetting, the
//  badge-color → ColorArray conversion, and that the default layer round-trips through UserDefaults
//  (per-tab does not — it's session-scoped).
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionActionStateTests: XCTestCase {

    private func makeState() -> (WebExtensionActionState, UserDefaults) {
        let suite = "test.action.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("test fixture could not create a UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return (WebExtensionActionState(userDefaults: defaults), defaults)
    }

    func testManifestProvidesBaseTitleAndPopup() {
        let (state, _) = makeState()
        state.registerManifestAction(extensionID: "ext", action: .init(
            defaultTitle: "My Action", defaultPopup: "popup.html", defaultIcon: ["32": "icon.png"]))
        let resolved = state.resolved(extensionID: "ext", tabId: nil)
        XCTAssertEqual(resolved.title, "My Action")
        XCTAssertEqual(resolved.popup, "popup.html")
        XCTAssertEqual(resolved.iconPath, "icon.png")
        XCTAssertEqual(resolved.badgeText, "")
        XCTAssertTrue(resolved.enabled)
    }

    func testActionIconFallsBackToTopLevelManifestIcons() {
        // An action that declares no icon must fall back to the manifest's top-level `icons` (Chrome
        // behaviour) instead of leaving the toolbar entry on the generic glyph.
        let (state, _) = makeState()
        state.registerManifestAction(extensionID: "ext",
                                     action: .init(defaultTitle: "T", defaultPopup: nil, defaultIcon: [:]),
                                     fallbackIcons: ["16": "icons/16.png", "48": "icons/48.png"])
        // Prefers a toolbar-sane size from the fallback set.
        XCTAssertEqual(state.resolved(extensionID: "ext", tabId: nil).iconPath, "icons/16.png")
    }

    func testActionIconPrefersActionOverTopLevelAndSkipsEmptyPaths() {
        let (state, _) = makeState()
        // An empty action-icon path must not be chosen; fall through to the non-empty fallback.
        state.registerManifestAction(extensionID: "ext",
                                     action: .init(defaultTitle: "T", defaultPopup: nil, defaultIcon: ["32": ""]),
                                     fallbackIcons: ["32": "fallback.png"])
        XCTAssertEqual(state.resolved(extensionID: "ext", tabId: nil).iconPath, "fallback.png")
    }

    func testDefaultLayerOverridesManifest() {
        let (state, _) = makeState()
        state.registerManifestAction(extensionID: "ext", action: .init(
            defaultTitle: "Manifest", defaultPopup: nil, defaultIcon: [:]))
        state.setTitle(extensionID: "ext", tabId: nil, title: "Runtime")
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "5")
        XCTAssertEqual(state.title(extensionID: "ext", tabId: nil), "Runtime")
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: nil), "5")
    }

    func testPerTabOverridesDefaultButNotOtherTabs() {
        let (state, _) = makeState()
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "default")
        state.setBadgeText(extensionID: "ext", tabId: 7, text: "tab7")
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: 7), "tab7")
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: 9), "default") // falls back to default
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: nil), "default")
    }

    func testEmptyBadgeTextClearsLayer() {
        let (state, _) = makeState()
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "9")
        state.setBadgeText(extensionID: "ext", tabId: 3, text: "tab")
        // Clearing the tab override re-exposes the default.
        state.setBadgeText(extensionID: "ext", tabId: 3, text: "")
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: 3), "9")
        // Clearing the default empties it entirely.
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "")
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: nil), "")
    }

    func testSetPopupEmptyStringDisablesPopupForOnClicked() {
        let (state, _) = makeState()
        state.registerManifestAction(extensionID: "ext", action: .init(
            defaultTitle: nil, defaultPopup: "popup.html", defaultIcon: [:]))
        // Explicit "" means "no popup" (Chrome → onClicked fires) and must beat the manifest default.
        state.setPopup(extensionID: "ext", tabId: nil, popup: "")
        XCTAssertNil(state.popupPath(extensionID: "ext", tabId: nil))
        // Setting a real popup path takes effect.
        state.setPopup(extensionID: "ext", tabId: nil, popup: "other.html")
        XCTAssertEqual(state.popupPath(extensionID: "ext", tabId: nil), "other.html")
    }

    func testEnableDisableScopedToTab() {
        let (state, _) = makeState()
        XCTAssertTrue(state.isEnabled(extensionID: "ext", tabId: 1))
        state.setEnabled(extensionID: "ext", tabId: 1, false)
        XCTAssertFalse(state.isEnabled(extensionID: "ext", tabId: 1))
        XCTAssertTrue(state.isEnabled(extensionID: "ext", tabId: 2))     // other tab unaffected
        state.setEnabled(extensionID: "ext", tabId: nil, false)
        XCTAssertFalse(state.isEnabled(extensionID: "ext", tabId: 2))    // default now disabled
    }

    func testForgetTabDropsOnlyThatTab() {
        let (state, _) = makeState()
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "def")
        state.setBadgeText(extensionID: "ext", tabId: 4, text: "four")
        state.forgetTab(4)
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: 4), "def") // override gone
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: nil), "def")
    }

    func testForgetExtensionClearsEverything() {
        let (state, _) = makeState()
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "x")
        state.setTitle(extensionID: "ext", tabId: 2, title: "t")
        state.forgetExtension("ext")
        XCTAssertEqual(state.badgeText(extensionID: "ext", tabId: nil), "")
        XCTAssertEqual(state.title(extensionID: "ext", tabId: 2), "")
    }

    func testBadgeColorBytesConversion() {
        let (state, _) = makeState()
        XCTAssertEqual(WebExtensionActionState.colorBytes("#ff0000"), [255, 0, 0, 255])
        XCTAssertEqual(WebExtensionActionState.colorBytes("#00ff0080"), [0, 255, 0, 128])
        XCTAssertEqual(WebExtensionActionState.colorBytes("#abc"), [170, 187, 204, 255])
        XCTAssertEqual(WebExtensionActionState.colorBytes("not-a-color"), [102, 102, 102, 255])
        state.setBadgeColor(extensionID: "ext", tabId: nil, color: "#102030")
        XCTAssertEqual(state.badgeColorBytes(extensionID: "ext", tabId: nil), [16, 32, 48, 255])
    }

    func testIconPathResolution() {
        XCTAssertEqual(WebExtensionActionState.iconPath(from: "x.png"), "x.png")
        XCTAssertEqual(WebExtensionActionState.iconPath(from: ["16": "a.png", "32": "b.png"]), "b.png")
        XCTAssertEqual(WebExtensionActionState.iconPath(from: ["48": "big.png"]), "big.png")
        XCTAssertNil(WebExtensionActionState.iconPath(from: ""))
        XCTAssertNil(WebExtensionActionState.iconPath(from: ["imageData": 1]))
    }

    func testDefaultLayerPersistsButPerTabDoesNot() {
        let (state, defaults) = makeState()
        state.setBadgeText(extensionID: "ext", tabId: nil, text: "persist")
        state.setBadgeText(extensionID: "ext", tabId: 5, text: "ephemeral")
        // A fresh instance over the same defaults reloads the default layer only.
        let reloaded = WebExtensionActionState(userDefaults: defaults)
        XCTAssertEqual(reloaded.badgeText(extensionID: "ext", tabId: nil), "persist")
        XCTAssertEqual(reloaded.badgeText(extensionID: "ext", tabId: 5), "persist") // per-tab not restored
    }

    func testChangeNotificationPostedWithTabId() {
        let (state, _) = makeState()
        let expectation = expectation(forNotification: WebExtensionActionState.didChangeNotification,
                                      object: nil) { note in
            (note.userInfo?["extensionID"] as? String) == "ext"
                && (note.userInfo?["tabId"] as? Int) == 11
        }
        state.setBadgeText(extensionID: "ext", tabId: 11, text: "n")
        wait(for: [expectation], timeout: 1)
    }
}
