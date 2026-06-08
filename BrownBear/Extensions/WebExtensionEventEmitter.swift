//
//  WebExtensionEventEmitter.swift
//  BrownBear
//
//  Turns the browser's tab + navigation lifecycle into chrome.tabs.* and chrome.webNavigation.*
//  events and fans them out (through WebExtensionRuntime) to every extension's background worker and
//  open popup. This is the PUSH side of Module 6: chrome.tabs/webNavigation events flow browser →
//  extension, unlike the request/response chrome.* surface in WebExtensionMessageRouter.
//
//  Chrome shapes:
//    tabs.onCreated(tab), onUpdated(tabId, changeInfo, tab), onActivated({tabId, windowId}),
//      onRemoved(tabId, {windowId, isWindowClosing})
//    webNavigation.onBeforeNavigate / onCommitted / onDOMContentLoaded / onCompleted /
//      onHistoryStateUpdated / onErrorOccurred — each a details object
//      {tabId, url, frameId, parentFrameId, timeStamp, [processId], [transitionType], [error]}.
//
//  Gating: chrome.tabs.* events need no permission (Chrome delivers them to any background/popup).
//  chrome.webNavigation.* events require the "webNavigation" permission, enforced per-extension by
//  the runtime fan-out (see dispatch(..., requiredPermission:)).
//
//  iOS reality: WKWebView gives us main-frame navigation only — no per-subframe webNavigation. Every
//  webNavigation detail therefore carries frameId 0 / parentFrameId -1 (the main frame), matching
//  how Chrome numbers the top frame. windowId is always 1 (single-window). See docs/WEB_EXTENSIONS.md.
//

import Foundation

@MainActor
final class WebExtensionEventEmitter {

    private let runtime: WebExtensionRuntime
    private let registry: WebExtensionTabRegistry
    /// Resolves a chrome tab id to the integer the rest of the runtime uses, and builds chrome Tab
    /// records. The browser VC owns the registry; we mint/look up ids through it so background
    /// workers, popups, and synchronous chrome.tabs.query all agree on a tab's id.
    private weak var host: WebExtensionBridgeHost?

    /// Last chrome Tab record we emitted per tab id, so onUpdated can diff and only report the
    /// properties that actually changed (Chrome's changeInfo is a delta, not the whole tab).
    private var lastRecords: [Int: [String: Any]] = [:]
    /// Properties Chrome surfaces in tabs.onUpdated changeInfo. We diff exactly these.
    private static let trackedKeys = ["status", "url", "title", "pinned", "audible", "discarded"]

    init(runtime: WebExtensionRuntime = BrownBearServices.shared.webExtensionRuntime,
         registry: WebExtensionTabRegistry,
         host: WebExtensionBridgeHost?) {
        self.runtime = runtime
        self.registry = registry
        self.host = host
    }

    /// Update the bridge host after the browser VC finishes loading (it sets itself as host late).
    func setHost(_ host: WebExtensionBridgeHost?) { self.host = host }

    // MARK: - chrome.tabs.* events

    /// A tab was opened. Fires chrome.tabs.onCreated(tab). Pass the chrome Tab record the host built
    /// for the new tab (the same `tabRecord(_:)` shape chrome.tabs.query returns).
    func tabCreated(_ tabRecord: [String: Any]) {
        if let id = tabRecord["id"] as? Int { lastRecords[id] = tabRecord }
        dispatch(name: "tabs.onCreated", args: [tabRecord])
    }

    /// A tab's observable state changed. Diffs against the last record we emitted and fires
    /// chrome.tabs.onUpdated(tabId, changeInfo, tab) only when a tracked property actually changed,
    /// so a flurry of KVO callbacks doesn't spam listeners with empty deltas.
    func tabUpdated(_ tabRecord: [String: Any]) {
        guard let id = tabRecord["id"] as? Int else { return }
        var changeInfo: [String: Any] = [:]
        let previous = lastRecords[id]
        for key in Self.trackedKeys {
            let newValue = tabRecord[key]
            let oldValue = previous?[key]
            if !Self.equalJSON(newValue, oldValue) {
                changeInfo[key] = newValue ?? NSNull()
            }
        }
        lastRecords[id] = tabRecord
        guard !changeInfo.isEmpty else { return }
        dispatch(name: "tabs.onUpdated", args: [id, changeInfo, tabRecord])
    }

    /// The active tab changed. Fires chrome.tabs.onActivated({tabId, windowId}).
    func tabActivated(extTabId: Int) {
        dispatch(name: "tabs.onActivated", args: [["tabId": extTabId, "windowId": 1]])
    }

    /// A tab was closed. Fires chrome.tabs.onRemoved(tabId, {windowId, isWindowClosing}). Resolve the
    /// id BEFORE the registry forgets the tab; pass `isWindowClosing` true only on full teardown.
    func tabRemoved(extTabId: Int, isWindowClosing: Bool = false) {
        lastRecords.removeValue(forKey: extTabId)
        dispatch(name: "tabs.onRemoved",
                 args: [extTabId, ["windowId": 1, "isWindowClosing": isWindowClosing]])
    }

    // MARK: - chrome.webNavigation.* events (require "webNavigation" permission)

    func webNavBeforeNavigate(extTabId: Int, url: String) {
        dispatch(name: "webNavigation.onBeforeNavigate",
                 args: [navDetails(extTabId: extTabId, url: url)], requiredPermission: "webNavigation")
    }

    func webNavCommitted(extTabId: Int, url: String, transitionType: String = "link") {
        var details = navDetails(extTabId: extTabId, url: url)
        details["transitionType"] = transitionType
        details["transitionQualifiers"] = [String]()
        dispatch(name: "webNavigation.onCommitted", args: [details], requiredPermission: "webNavigation")
    }

    func webNavDOMContentLoaded(extTabId: Int, url: String) {
        dispatch(name: "webNavigation.onDOMContentLoaded",
                 args: [navDetails(extTabId: extTabId, url: url)], requiredPermission: "webNavigation")
    }

    func webNavCompleted(extTabId: Int, url: String) {
        dispatch(name: "webNavigation.onCompleted",
                 args: [navDetails(extTabId: extTabId, url: url)], requiredPermission: "webNavigation")
    }

    /// A same-document history change (pushState/replaceState/hash) — Chrome's onHistoryStateUpdated.
    func webNavHistoryStateUpdated(extTabId: Int, url: String) {
        var details = navDetails(extTabId: extTabId, url: url)
        details["transitionType"] = "link"
        details["transitionQualifiers"] = [String]()
        dispatch(name: "webNavigation.onHistoryStateUpdated",
                 args: [details], requiredPermission: "webNavigation")
    }

    func webNavErrorOccurred(extTabId: Int, url: String, error: String) {
        var details = navDetails(extTabId: extTabId, url: url)
        details["error"] = error
        dispatch(name: "webNavigation.onErrorOccurred", args: [details], requiredPermission: "webNavigation")
    }

    // MARK: - Helpers

    /// The webNavigation details object common to every event. iOS exposes only the main frame, so
    /// frameId is 0 and parentFrameId is -1 (Chrome's numbering for the top frame).
    private func navDetails(extTabId: Int, url: String) -> [String: Any] {
        [
            "tabId": extTabId,
            "url": url,
            "frameId": 0,
            "parentFrameId": -1,
            "processId": 0,
            "timeStamp": Date().timeIntervalSince1970 * 1000
        ]
    }

    /// Serialize the args array once and hand the JSON string to the runtime fan-out. Doing the
    /// JSON-encode here (on the main actor, where the args were built) keeps the background contexts'
    /// serial queues from ever touching these Swift dictionaries.
    private func dispatch(name: String, args: [Any], requiredPermission: String? = nil) {
        let argsJSON = Self.jsonString(args)
        runtime.dispatchEventToAll(name: name, argsJSON: argsJSON, requiredPermission: requiredPermission)
    }

    /// Loose JSON equality for changeInfo diffing — covers the scalar/string values our tab records
    /// hold (String, Int, Bool) plus nil. Anything else is treated as changed (fires, never silent).
    private static func equalJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l as String, r as String): return l == r
        case let (l as Bool, r as Bool): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        default: return false
        }
    }

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }
}

/// A live extension PAGE (popup/options) that wants browser-pushed chrome.tabs/webNavigation events.
/// The page VC registers itself with the runtime for its lifetime; the runtime fans events to it by
/// evaluating into its web view via the BBWebKitBridge ObjC shim (never the Swift WebKit overlay).
@MainActor
protocol WebExtensionEventReceiver: AnyObject {
    /// The extension this page belongs to — the runtime delivers only that extension's events.
    var receiverExtensionID: String { get }
    /// The extension's granted API permissions, so the runtime can gate webNavigation.* like Chrome.
    var receiverPermissions: Set<String> { get }
    /// Deliver one already-serialized event into the page's chrome.* surface.
    func dispatchExtEvent(name: String, argsJSON: String)
    /// Deliver a runtime.sendMessage into this page's chrome.runtime.onMessage and await the first
    /// sendResponse. `senderToken` is the sending page's token (when the sender is itself a page) so a
    /// page never receives its own broadcast. Returns `["value": ...]` for an answer, nil otherwise.
    func deliverRuntimeMessage(message: Any, sender: [String: Any], senderToken: String?) async -> [String: Any]?
}

extension WebExtensionEventReceiver {
    /// Default: an event-only receiver does not handle runtime messages.
    func deliverRuntimeMessage(message: Any, sender: [String: Any], senderToken: String?) async -> [String: Any]? {
        nil
    }
}
