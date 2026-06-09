//
//  WebExtensionPageSession.swift
//  BrownBear
//
//  The chrome.* bridge engine behind an extension PAGE — its popup or options page — decoupled from
//  how that page is hosted. WebExtensionPageViewController hosts it in a sheet (popups); the browser
//  hosts an options page in a real tab (chrome.runtime.openOptionsPage / the "•••" menu Options
//  action / chrome.tabs.create of a chrome-extension:// URL). Both share this one engine, so a
//  tab-hosted page behaves identically to a sheet: same per-extension scheme handler, same
//  brownbear-webext-page.js runtime, the same live storage/cookie/notification push, and the same
//  chrome.runtime.connect port delivery into the page.
//

import UIKit
import WebKit

@MainActor
final class WebExtensionPageSession {

    enum Kind {
        case popup
        case options
        /// An MV3 `chrome.offscreen` document — the same page engine, but hosted in a hidden WKWebView
        /// (no UI) so a DOM-less service worker can do DOM work. Always loads an explicit packaged path.
        case offscreen

        var title: String {
            switch self {
            case .popup: return "Popup"
            case .options: return "Options"
            case .offscreen: return "Offscreen document"
            }
        }
    }

    let ext: WebExtension
    let kind: Kind
    /// A specific packaged resource to load instead of the manifest's kind-default page (used when an
    /// extension opens an arbitrary `chrome-extension://<id>/<path>` of its own via chrome.tabs.create).
    private let explicitPath: String?

    private let store: WebExtensionStore
    private let storage: WebExtensionStorage
    private let runtime: WebExtensionRuntime

    let router: WebExtensionMessageRouter
    let schemeHandler: WebExtensionSchemeHandler
    let contentWorld = WKContentWorld.page

    private weak var webView: WKWebView?
    private var storageObserver: NSObjectProtocol?
    private var cookieObserver: NSObjectProtocol?
    private var notificationObserver: NSObjectProtocol?
    /// This page's session token, retained so its open chrome.runtime ports can be torn down on dismiss.
    private var pageToken: String?

    init(ext: WebExtension,
         kind: Kind,
         path: String? = nil,
         store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         storage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage,
         runtime: WebExtensionRuntime = BrownBearServices.shared.webExtensionRuntime) {
        self.ext = ext
        self.kind = kind
        self.explicitPath = path
        self.store = store
        self.storage = storage
        self.runtime = runtime
        self.router = WebExtensionMessageRouter(store: store, storage: storage, runtime: runtime,
                                                contentWorld: contentWorld)
        self.schemeHandler = WebExtensionSchemeHandler(extensionID: ext.id, store: store)
        // The page runs its own router instance, so give it the same chrome.tabs + chrome.cookies
        // bridges the runtime holds (set when the browser VC loaded), or pages couldn't reach them.
        self.router.host = runtime.host
        self.router.cookieHost = runtime.cookieHost
    }

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        if let cookieObserver { NotificationCenter.default.removeObserver(cookieObserver) }
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    }

    // MARK: - The page path

    /// The manifest-declared file for this kind (or the explicit override), or nil if none exists.
    var pagePath: String? {
        if let explicitPath, !explicitPath.isEmpty { return explicitPath }
        switch kind {
        case .popup: return ext.manifest?.action?.defaultPopup
        case .options: return ext.manifest?.optionsPage
        case .offscreen: return nil   // offscreen always supplies an explicit path (handled above)
        }
    }

    /// The chrome-extension:// URL of this page, or nil if the extension declares no such page.
    var pageURL: URL? {
        guard let path = pagePath, !path.isEmpty else { return nil }
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return URL(string: "\(WebExtensionSchemeHandler.scheme)://\(ext.id)/\(trimmed)")
    }

    // MARK: - Configuration

    /// Build a WKWebView configuration carrying this extension's scheme handler and the page bridge:
    /// the message handler, the document-start `__bbExtPage` bootstrap, and brownbear-webext-page.js.
    /// Async because it reads the extension's default-locale i18n messages. Mints the page session
    /// token (so `bind(to:)` can attach the live web view afterwards).
    func makeConfiguration() async -> WKWebViewConfiguration {
        let messages = await loadMessages()
        let token = router.makePageSession(for: ext.id)
        self.pageToken = token

        let bootstrapData: [String: Any] = [
            "token": token,
            "extensionId": ext.id,
            "manifestJSON": ext.manifestJSON,
            "baseURL": ext.baseURLString,
            "messages": messages
        ]
        let dataJSON = Self.jsonString(bootstrapData)

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(router, contentWorld: contentWorld, name: WebExtensionMessageRouter.handlerName)
        controller.addUserScript(WKUserScript(source: "window.__bbExtPage = \(dataJSON);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.pageRuntimeSource,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebExtensionSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    /// Bind the session to its web view after creation (the token was minted before the view existed):
    /// route chrome.runtime.connect ports into the page, and start the live storage/cookie/notification
    /// push plus browser-pushed chrome.tabs.*/webNavigation.* events.
    func bind(to webView: WKWebView) {
        self.webView = webView
        if let pageToken {
            router.attachPageWebView(token: pageToken, webView: webView)
        }
        observeStorageChanges()
        runtime.registerEventReceiver(self)
    }

    /// Tear down: stop receiving browser-pushed events and disconnect any ports this page opened, so the
    /// worker's onDisconnect fires rather than stranding the channel against a closed/dismissed view.
    func invalidate() {
        runtime.unregisterEventReceiver(self)
        if let pageToken {
            runtime.portHub.disconnectClientPorts(tokens: [pageToken])
        }
    }

    // MARK: - i18n

    /// Load the default-locale messages.json (flattened) for chrome.i18n, mirroring the content side.
    private func loadMessages() async -> [String: String] {
        guard let locale = ext.manifest?.defaultLocale,
              let data = await store.file(extensionID: ext.id, path: "_locales/\(locale)/messages.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (key, value) in json {
            if let entry = value as? [String: Any], let message = entry["message"] as? String {
                out[key] = message
            }
        }
        return out
    }

    // MARK: - storage.onChanged / cookies / notifications push

    private func observeStorageChanges() {
        storageObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionStorageDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleStorageChange(note) }
        }
        cookieObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionCookieDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleCookieChange(note) }
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionNotificationEvent, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleNotificationEvent(note) }
        }
    }

    /// Deliver a chrome.notifications event to an open page's listeners.
    private func handleNotificationEvent(_ note: Notification) {
        guard let info = note.userInfo,
              info["extensionID"] as? String == ext.id,
              let kind = info["kind"] as? String,
              let notificationID = info["notificationID"] as? String,
              let webView else { return }
        let idJSON = Self.jsonString(notificationID)
        let js: String
        switch kind {
        case "clicked":
            js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchNotificationClicked(\(idJSON));"
        case "closed":
            let byUser = (info["byUser"] as? Bool) ?? false
            js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchNotificationClosed(\(idJSON), \(byUser));"
        case "buttonClicked":
            let idx = (info["buttonIndex"] as? Int) ?? 0
            js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchNotificationButtonClicked(\(idJSON), \(idx));"
        default:
            return
        }
        BBEvaluateJavaScript(webView, js, contentWorld)   // ObjC shim — no Swift WebKit overlay (iOS 16.4).
    }

    /// Push a cookie change into an open page's chrome.cookies.onChanged. Double-encoded (a JSON string
    /// the page JS will _JSON.parse), matching dispatchStorageChanged.
    private func handleCookieChange(_ note: Notification) {
        guard let change = note.userInfo?["change"] as? [String: Any], let webView else { return }
        let js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchCookieChanged("
            + "\(Self.jsonString(Self.jsonString(change))));"
        BBEvaluateJavaScript(webView, js, contentWorld)
    }

    private func handleStorageChange(_ note: Notification) {
        guard let info = note.userInfo,
              info["extensionID"] as? String == ext.id,
              let area = info["area"] as? String,
              let changes = info["changes"] as? [String: [String: String]],
              let webView else { return }
        let changesJSON = Self.jsonString(changes)
        let js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchStorageChanged(\(Self.jsonString(area)), \(Self.jsonString(changesJSON)));"
        // Via the ObjC shim so we don't link the Swift WebKit overlay (see BBWebKitBridge.h).
        BBEvaluateJavaScript(webView, js, contentWorld)
    }

    // MARK: - Helpers

    private static func jsonString(_ value: Any) -> String {
        JSONSanitize.string(value)
    }

    private static let pageRuntimeSource: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-webext-page", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-webext-page", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* brownbear-webext-page.js missing */"
        }
        return source
    }()
}

extension WebExtensionPageSession: WebExtensionEventReceiver {
    var receiverExtensionID: String { ext.id }
    var receiverPermissions: Set<String> { Set(ext.manifest?.permissions ?? []) }

    /// Deliver a browser-pushed chrome.tabs/webNavigation event into this page's chrome.* surface.
    func dispatchExtEvent(name: String, argsJSON: String) {
        // An offscreen document has no chrome.tabs/webNavigation surface in Chrome — it must still be a
        // registered event receiver (that's how it gets runtime.sendMessage via deliverRuntimeMessage),
        // but browser-pushed tab/navigation events are not delivered to it.
        if kind == .offscreen { return }
        guard let webView else { return }
        let js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchExtEvent("
            + "\(Self.jsonString(name)), \(Self.jsonString(argsJSON)));"
        BBEvaluateJavaScript(webView, js, contentWorld)   // ObjC shim — no Swift WebKit overlay (iOS 16.4).
    }

    /// Deliver a runtime.sendMessage into this page's chrome.runtime.onMessage. Skipped if this page is
    /// itself the sender (Chrome never delivers a context its own broadcast) or has no live web view.
    func deliverRuntimeMessage(message: Any, sender: [String: Any], senderToken: String?) async -> [String: Any]? {
        guard let pageToken, senderToken != pageToken, webView != nil else { return nil }
        return await router.deliverRuntimeMessageToPage(token: pageToken, message: message, sender: sender)
    }

    /// This page's chrome.runtime.getContexts record (popup → POPUP, options → TAB, offscreen →
    /// OFFSCREEN_DOCUMENT). Only listed while the web view is live. The offscreen document is reported
    /// here too — it's a registered event receiver — so getContexts needs no separate offscreen lookup.
    func contextRecord() -> [String: Any]? {
        guard webView != nil, let pageToken else { return nil }
        let contextType: String
        switch kind {
        case .popup: contextType = "POPUP"
        case .options: contextType = "TAB"
        case .offscreen: contextType = "OFFSCREEN_DOCUMENT"
        }
        // An offscreen document isn't associated with a top frame or a window — Chrome reports
        // frameId/windowId as -1 for it (unlike a popup/options page, which lives in the lone window).
        let isOffscreen = kind == .offscreen
        return [
            "contextId": pageToken,
            "contextType": contextType,
            "documentId": pageToken,
            "documentUrl": pageURL?.absoluteString ?? NSNull(),
            "documentOrigin": "\(WebExtensionSchemeHandler.scheme)://\(ext.id)",
            "frameId": isOffscreen ? -1 : 0,
            "tabId": -1,
            "windowId": isOffscreen ? -1 : BrownBearBrowserViewController.webExtWindowID,
            "incognito": false
        ]
    }

    /// Whether a runtime.sendMessage can actually be delivered into this page (its web view is live).
    /// The runtime uses this so a registered-but-dead page doesn't count as a receiver and wrongly
    /// suppress chrome.runtime.lastError's "no receiving end" signal.
    var isDeliverable: Bool { webView != nil }
}
