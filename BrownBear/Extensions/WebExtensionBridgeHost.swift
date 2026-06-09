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

import WebKit

@MainActor
protocol WebExtensionBridgeHost: AnyObject {
    /// chrome.tabs.query — open tabs filtered by the supported query properties.
    func webExtQueryTabs(_ query: [String: Any]) -> [[String: Any]]
    /// chrome.tabs.get / getCurrent — one tab record (`nil` ext id = the active tab), or nil if gone.
    func webExtTab(extTabId: Int?) -> [String: Any]?
    /// The chrome.tabs Tab record for the tab whose web view is `webView`, or nil if `webView` is not a
    /// browser tab (e.g. an extension popup/options page). Lets the runtime put the real `tab` on a
    /// content script's chrome.runtime.MessageSender, so the receiver can reply via
    /// chrome.tabs.sendMessage(sender.tab.id, …). Chrome attaches `tab` to a sender iff it runs in a tab.
    func webExtTabRecord(forWebView webView: WKWebView) -> [String: Any]?
    /// chrome.tabs.create — open a tab (optionally loading `url`, optionally activating it). Returns it.
    func webExtCreateTab(url: String?, active: Bool) -> [String: Any]
    /// chrome.tabs.update — navigate and/or activate a tab (`nil` ext id = the active tab). Returns it.
    func webExtUpdateTab(extTabId: Int?, url: String?, active: Bool?) -> [String: Any]?
    /// chrome.tabs.remove — close the tabs with these ext ids.
    func webExtRemoveTabs(extTabIds: [Int])
    /// chrome.tabs.reload — reload a tab (`nil` ext id = the active tab).
    func webExtReloadTab(extTabId: Int?, bypassCache: Bool)

    /// chrome.tabs.move — reorder the given tabs to position `index` (`< 0` = end). Returns the moved
    /// tab records in their new order. iOS is single-window, so windowId is ignored.
    func webExtMoveTabs(extTabIds: [Int], index: Int) -> [[String: Any]]
    /// chrome.tabs.duplicate — open a new tab loading the same URL as `extTabId`. Returns the new tab.
    func webExtDuplicateTab(extTabId: Int) -> [String: Any]?
    /// chrome.tabs.getZoom — the tab's current zoom factor (1.0 = 100%); `nil` id = the active tab.
    func webExtGetZoom(extTabId: Int?) -> Double
    /// chrome.tabs.setZoom — set the tab's zoom factor (`0` = reset to the default 1.0; clamped to a
    /// sane range); `nil` id = the active tab.
    func webExtSetZoom(extTabId: Int?, factor: Double)

    /// chrome.search.query — run a web search for `text` using the user's default search engine.
    /// `disposition` is "CURRENT_TAB" (default), "NEW_TAB", or "NEW_WINDOW" (treated as NEW_TAB — iOS is
    /// single-window); `extTabId` (when set, with CURRENT_TAB) targets that tab instead of the active one.
    func webExtSearchQuery(text: String, disposition: String?, extTabId: Int?)

    // chrome.bookmarks / chrome.history / chrome.sessions — read-only views of the user's own browsing
    // data, backed by BrownBear's BookmarkStore / HistoryStore / TabManager.recentlyClosed. The native
    // bridge gates each on the matching manifest permission (bookmarks/history/sessions) before calling
    // these, so an undeclared script reaches none of it (§5). bookmarks/history read actor stores (async).
    /// chrome.bookmarks.getTree — the full bookmark tree (a synthetic root over BrownBear's flat list).
    func webExtBookmarksTree() async -> [[String: Any]]
    /// chrome.bookmarks.search — bookmarks whose title/URL contains `query` (blank = all).
    func webExtBookmarksSearch(query: String) async -> [[String: Any]]
    /// chrome.history.search — visited entries matching `text` (blank = most recent), capped at `maxResults`.
    func webExtHistorySearch(text: String, maxResults: Int) async -> [[String: Any]]
    /// chrome.sessions.getRecentlyClosed — the recently-closed tabs as Session records (newest first).
    func webExtSessionsRecentlyClosed(maxResults: Int) -> [[String: Any]]
    /// chrome.sessions.restore — reopen a recently-closed tab (`sessionId` nil/unknown = most recent).
    /// Returns the restored Session, or nil if there was nothing to restore.
    func webExtSessionsRestore(sessionId: String?) -> [String: Any]?

    // chrome.bookmarks / chrome.history WRITE ops — mutate the user's own bookmarks / history via
    // BookmarkStore / HistoryStore. Same permission gate as the reads (bookmarks/history). Used by
    // keyboard-nav extensions (Surfingkeys / Vimium C) for bookmark + history keybindings.
    /// chrome.bookmarks.create — add a bookmark; returns the created node (nil if the URL is invalid).
    func webExtBookmarksCreate(title: String, url: String) async -> [String: Any]?
    /// chrome.bookmarks.remove — delete the bookmark with this id (the stable UUID string).
    func webExtBookmarksRemove(id: String) async
    /// chrome.history.addUrl — record a visit to `url` (with optional title).
    func webExtHistoryAddUrl(url: String, title: String?) async
    /// chrome.history.deleteUrl — remove all history entries for `url`.
    func webExtHistoryDeleteUrl(url: String) async
    /// chrome.history.deleteRange — remove history entries whose last visit is within [startMs, endMs]
    /// (epoch milliseconds).
    func webExtHistoryDeleteRange(startMs: Double, endMs: Double) async

    /// chrome.scripting.executeScript / chrome.tabs.executeScript — run `code` in a tab (`nil` ext id =
    /// active) and return one `{result, frameId}` per frame. `world` is "MAIN" (page) or "ISOLATED"
    /// (the extension content world). Main frame only on iOS.
    func webExtExecuteScript(extTabId: Int?, world: String, code: String) async -> [[String: Any]]
    /// chrome.scripting.insertCSS / chrome.tabs.insertCSS — inject CSS into a tab.
    func webExtInsertCSS(extTabId: Int?, css: String)
    /// chrome.scripting.removeCSS — remove CSS previously inserted (matched by its exact text).
    func webExtRemoveCSS(extTabId: Int?, css: String)

    /// chrome.tabs.sendMessage — deliver `message` to the content scripts of `extensionID` running in
    /// the tab `extTabId` (`nil` = the active tab), resolving with the first listener's response (or
    /// `nil` if no tab/listener answered). `frameId` `nil` = all frames; iOS delivers to the tab's main
    /// frame. Routed through the shared content runtime, which owns the per-tab content sessions — so a
    /// popup or background worker (each with its own router) still reaches the page's content scripts.
    func webExtSendMessageToTab(extensionID: String, extTabId: Int?, message: Any, frameId: Int?) async -> Any?

    // chrome.notifications — backed by UNUserNotificationCenter via WebExtensionNotificationManager.
    // These are async (UN is async) and throw (the "notifications" permission is enforced inside the
    // manager). `extensionID` is required to gate the permission and namespace the notification.
    /// chrome.notifications.create — returns the effective notification id (supplied or minted).
    func webExtNotificationsCreate(extensionID: String, notificationID: String?, options: [String: Any]) async throws -> String
    /// chrome.notifications.update — returns whether a notification with that id existed.
    func webExtNotificationsUpdate(extensionID: String, notificationID: String, options: [String: Any]) async throws -> Bool
    /// chrome.notifications.clear — returns whether a notification with that id was present.
    func webExtNotificationsClear(extensionID: String, notificationID: String) async throws -> Bool
    /// chrome.notifications.getAll — this extension's live notification ids as { id: true }.
    func webExtNotificationsGetAll(extensionID: String) async throws -> [String: Bool]

    /// chrome.action — the chrome tab id of the active tab (`nil` = no tab). Resolves the default tab
    /// for a tab-less setBadgeText/getTitle/etc.
    func webExtActionActiveTabId() -> Int?
    /// chrome.action — the visible click on an extension's overflow-menu action entry: open its popup
    /// if one is resolved for the active tab, otherwise fire chrome.action.onClicked into the worker.
    func webExtTriggerAction(extensionID: String)

    /// chrome.windows.get / getCurrent / getLastFocused — the lone synthetic window (iOS is single-
    /// window). `populate` includes the tab list in the record.
    func webExtWindow(populate: Bool) -> [String: Any]
    /// chrome.windows.getAll — always exactly one window on iOS.
    func webExtAllWindows(populate: Bool) -> [[String: Any]]
    /// chrome.windows.create — degrades to a new tab in the lone window; returns that window.
    func webExtCreateWindow(url: String?, active: Bool, populate: Bool) -> [String: Any]
    /// chrome.windows.update — geometry/state/focus aren't expressible on iOS; returns the window.
    func webExtUpdateWindow(populate: Bool) -> [String: Any]
    /// chrome.runtime.openOptionsPage — open the extension's real options page (tab or sheet). Returns
    /// false if the extension is unknown or has no options page (so JS can populate lastError).
    @discardableResult
    func webExtOpenOptionsPage(extensionID: String) -> Bool

    /// Open an arbitrary extension page (`<scheme>://<id>/<path>`) as a real browser tab — the path an
    /// extension popup hands to `window.open()` / a `target="_blank"` link (ScriptCat opens its options
    /// and new-script pages this way, not via chrome.runtime.openOptionsPage). Returns false if the
    /// extension/page is unknown. `path` is the requested resource path (e.g. "/src/options.html").
    @discardableResult
    func webExtOpenExtensionPage(extensionID: String, path: String) -> Bool

    /// A view to parent a chrome.offscreen document's hidden WKWebView into, so its JS/timers keep
    /// running (an off-window web view can be suspended by WebKit). The browser returns its root view;
    /// the offscreen manager positions the web view off-screen behind all chrome. nil ⇒ no window yet,
    /// in which case createDocument rejects.
    func webExtOffscreenContainer() -> UIView?

    /// chrome.tabs.captureVisibleTab — snapshot the active tab's web view and return a `data:` URL in the
    /// requested format ("png"/"jpeg", quality 0–100 for jpeg). `permit` is evaluated against the captured
    /// tab's CURRENT URL immediately before the snapshot, so the gate and the capture are atomic (no
    /// TOCTOU); returns nil if there's no capturable tab OR `permit` denies it.
    func webExtCaptureVisibleTab(format: String, quality: Int, permit: (String?) -> Bool) async -> String?
}

/// The native side of `chrome.cookies` — the browser implements it over the shared WKHTTPCookieStore
/// (BrownBearBrowserViewController+Cookies). Kept separate from `WebExtensionBridgeHost` so the cookie
/// surface can be wired (and gated) independently of the tab surface. iOS exposes one cookie store.
@MainActor
protocol WebExtensionCookieBridgeHost: AnyObject {
    /// chrome.cookies.get — the single cookie matching `name` that would be sent to `url`, or nil.
    func webExtGetCookie(url: String, name: String, storeId: String?) async -> [String: Any]?
    /// chrome.cookies.getAll — every cookie matching the (already-validated) filter dictionary.
    func webExtGetAllCookies(filter: [String: Any], storeId: String?) async -> [[String: Any]]
    /// chrome.cookies.set — create/overwrite a cookie from the chrome setDetails; returns the result.
    func webExtSetCookie(details: [String: Any], storeId: String?) async -> [String: Any]?
    /// chrome.cookies.remove — delete the cookie matching `name`+`url`; returns the removal details.
    func webExtRemoveCookie(url: String, name: String, storeId: String?) async -> [String: Any]?
    /// chrome.cookies.getAllCookieStores — iOS has exactly one store ("0").
    func webExtGetAllCookieStores() -> [[String: Any]]
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
