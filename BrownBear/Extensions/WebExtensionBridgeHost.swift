//
//  WebExtensionBridgeHost.swift
//  BrownBear
//
//  Lets the web-extension runtime drive the browser's tabs — the native side of `chrome.tabs`. The
//  browser view controller implements it over `TabManager`; the content-script bridge
//  (WebExtensionMessageRouter), extension popups, and the headless background workers all reach it
//  through `InjectionOrchestrator`. Mirrors the userscript `ScriptBridgeHost` pattern (which only does
//  GM_openInTab) with the fuller tab surface real extensions need.
//
//  chrome.tab ids are integers, but BrownBear's `Tab.id` is a UUID, so `WebExtensionTabRegistry` mints
//  a stable small integer per tab and remembers it for the tab's lifetime.
//

import Foundation

@MainActor
protocol WebExtensionBridgeHost: AnyObject {
    /// chrome.tabs.query — open tabs filtered by the supported query properties.
    func webExtQueryTabs(_ query: [String: Any]) -> [[String: Any]]
    /// chrome.tabs.get / getCurrent — one tab record (`nil` ext id = the active tab), or nil if gone.
    func webExtTab(extTabId: Int?) -> [String: Any]?
    /// chrome.tabs.create — open a tab (optionally loading `url`, optionally activating it). Returns it.
    func webExtCreateTab(url: String?, active: Bool) -> [String: Any]
    /// chrome.tabs.update — navigate and/or activate a tab (`nil` ext id = the active tab). Returns it.
    func webExtUpdateTab(extTabId: Int?, url: String?, active: Bool?) -> [String: Any]?
    /// chrome.tabs.remove — close the tabs with these ext ids.
    func webExtRemoveTabs(extTabIds: [Int])
    /// chrome.tabs.reload — reload a tab (`nil` ext id = the active tab).
    func webExtReloadTab(extTabId: Int?, bypassCache: Bool)

    /// chrome.scripting.executeScript / chrome.tabs.executeScript — run `code` in a tab (`nil` ext id =
    /// active) and return one `{result, frameId}` per frame. `world` is "MAIN" (page) or "ISOLATED"
    /// (the extension content world). Main frame only on iOS.
    func webExtExecuteScript(extTabId: Int?, world: String, code: String) async -> [[String: Any]]
    /// chrome.scripting.insertCSS / chrome.tabs.insertCSS — inject CSS into a tab.
    func webExtInsertCSS(extTabId: Int?, css: String)
    /// chrome.scripting.removeCSS — remove CSS previously inserted (matched by its exact text).
    func webExtRemoveCSS(extTabId: Int?, css: String)
}

/// Stable bidirectional `UUID (Tab.id) ↔ Int (chrome tab id)` map. chrome.tabs ids must be integers
/// and stable for a tab's lifetime; we mint a monotonic counter the first time a tab is exposed.
@MainActor
final class WebExtensionTabRegistry {

    private var idForUUID: [UUID: Int] = [:]
    private var uuidForID: [Int: UUID] = [:]
    private var counter = 0

    /// The integer id for a tab, minting (and remembering) one on first use.
    func id(for uuid: UUID) -> Int {
        if let existing = idForUUID[uuid] { return existing }
        counter += 1
        idForUUID[uuid] = counter
        uuidForID[counter] = uuid
        return counter
    }

    /// The tab UUID a chrome tab id maps to, if still known.
    func uuid(for id: Int) -> UUID? { uuidForID[id] }

    /// Drop a closed tab's mapping so a stale id never resolves to a reused slot.
    func forget(uuid: UUID) {
        if let id = idForUUID.removeValue(forKey: uuid) { uuidForID.removeValue(forKey: id) }
    }
}
