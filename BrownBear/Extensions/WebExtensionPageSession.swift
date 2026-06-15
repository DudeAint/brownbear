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
        /// A `chrome_url_overrides.newtab` page (Momentum, Tabliss, …) shown in a real tab IN PLACE of the
        /// built-in New Tab page. Same page engine as options (full UI + chrome.* bridge); always loads an
        /// explicit packaged path. Normal tabs can't load chrome-extension://, so a new tab that should show
        /// an override is created with this session's per-extension configuration instead.
        case newtab
        /// A side-panel page — Chrome MV3 `chrome.sidePanel` / Firefox `sidebar_action`. Same page engine
        /// as a popup/options page (full UI + chrome.* bridge); the page path comes from the manifest
        /// (`side_panel.default_path` / `sidebar_action.default_panel`) or a `sidePanel.setOptions({path})`
        /// override passed in. iOS has no docked panel, so it's hosted as a sheet over the page.
        case sidebar

        var title: String {
            switch self {
            case .popup: return "Popup"
            case .options: return "Options"
            case .offscreen: return "Offscreen document"
            case .newtab: return "New Tab"
            case .sidebar: return "Side panel"
            }
        }

        /// A stable token the page runtime reads from `window.__bbExtPage.kind`. The offscreen document
        /// uses it to register itself as a service-worker client, so the DOM-less worker can reach it via
        /// `clients.matchAll()` + `client.postMessage` (Stylus offloads usercss parsing, blob URLs and
        /// prefers-color-scheme to its offscreen document over that channel).
        var configValue: String {
            switch self {
            case .popup: return "popup"
            case .options: return "options"
            case .offscreen: return "offscreen"
            case .newtab: return "newtab"
            case .sidebar: return "sidebar"
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
        self.schemeHandler = WebExtensionSchemeHandler(extensionID: ext.id, scheme: ext.scheme, store: store)
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
        case .newtab: return ext.manifest?.newTabOverride
        case .sidebar: return ext.manifest?.sidePanelPath   // a setOptions override is passed via explicitPath
        }
    }

    /// The extension-scheme URL of this page (chrome- or moz-extension per the build), or nil if the
    /// extension declares no such page.
    var pageURL: URL? {
        guard let path = pagePath, !path.isEmpty else { return nil }
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return URL(string: "\(ext.scheme)://\(ext.id)/\(trimmed)")
    }

    // MARK: - Configuration

    /// Build a WKWebView configuration carrying this extension's scheme handler and the page bridge:
    /// the message handler, the document-start `__bbExtPage` bootstrap, and brownbear-webext-page.js.
    /// Async because it reads the extension's default-locale i18n messages. Mints the page session
    /// token (so `bind(to:)` can attach the live web view afterwards).
    func makeConfiguration() async -> WKWebViewConfiguration {
        let loaded = await loadMessages()
        let token = router.makePageSession(for: ext.id)
        self.pageToken = token

        let bootstrapData: [String: Any] = [
            "token": token,
            "extensionId": ext.id,
            "manifestJSON": ext.manifestJSON,
            "baseURL": ext.baseURLString,
            "messages": loaded.messages,
            "placeholders": loaded.placeholders,
            "kind": kind.configValue
        ]
        let dataJSON = Self.jsonString(bootstrapData)

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(router, contentWorld: contentWorld, name: WebExtensionMessageRouter.handlerName)
        // requestIdleCallback polyfill FIRST (all frames — the dashboard loads its panes in iframes), before
        // any page script. WebKit ships none; a page that calls it during init (uBlock Origin Lite's
        // dashboard) would otherwise throw a bare ReferenceError and render blank.
        controller.addUserScript(WKUserScript(source: Self.idlePolyfillSource,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // IndexedDB engine, injected ONLY when the page origin has no working IndexedDB. WKWebView gives the
        // chrome-extension:// custom-scheme page origin no DOM storage (the same gap as window.localStorage),
        // so a page that opens an IndexedDB database — Momentum's Dexie data layer, ScriptCat, … — throws
        // "IndexedDB API missing" or hangs. Our in-memory engine self-installs globalThis.indexedDB; the
        // guard leaves a real, working IndexedDB untouched. Before the page bootstrap so the page's own
        // scripts see it. (In-memory per page load for now; native-backed persistence is a follow-up.)
        controller.addUserScript(WKUserScript(source: Self.idbPolyfillSource,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Opt-in (default OFF): persist this page's in-memory IndexedDB across reloads, the way the background
        // worker already does via BrownBearIDBStore. Gated because the rehydrate replays asynchronously in a
        // WKWebView (unlike the JSContext's synchronous microtask drain), so it needs on-device verification
        // that the snapshot lands before the page opens its DB. Default-off ⇒ a provable no-op for everyone
        // who hasn't opted in. Page snapshots use the `.extPage` namespace — distinct from the worker's `.ext`.
        if Self.persistPageIDBEnabled {
            Self.installPageIDBPersistence(into: controller, extensionID: ext.id)
        }
        controller.addUserScript(WKUserScript(source: "window.__bbExtPage = \(dataJSON);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Native-backed window.localStorage for this page: seed the last snapshot + wire the save sink BEFORE
        // the page runtime installs its Storage polyfill, so the page reads its own writes back across reopen
        // (the chrome-extension:// origin has no real DOM storage). Always on — localStorage is expected to
        // persist; the seed is synchronous (a document-start literal) so the first read already sees prior data.
        Self.installPageLocalStoragePersistence(into: controller, extensionID: ext.id)
        controller.addUserScript(WKUserScript(source: Self.pageRuntimeSource,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ext.scheme)
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
        // Best-effort final IndexedDB snapshot before teardown — the persist layer's 300 ms debounce may not
        // have fired for the very last write. No-op when persistence is off or the page never used IndexedDB.
        if Self.persistPageIDBEnabled {
            webView?.evaluateJavaScript("try{if(typeof __bbIDBFlush==='function'){__bbIDBFlush();}}catch(e){}",
                                        completionHandler: nil)
        }
        runtime.unregisterEventReceiver(self)
        if let pageToken {
            runtime.portHub.disconnectClientPorts(tokens: [pageToken])
        }
    }

    // MARK: - i18n

    /// Load the default-locale messages.json (flattened) for chrome.i18n, mirroring the content side.
    private func loadMessages() async -> (messages: [String: String], placeholders: [String: [String: String]]) {
        guard let locale = ext.manifest?.defaultLocale,
              let data = await store.file(extensionID: ext.id, path: "_locales/\(locale)/messages.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([:], [:])
        }
        var out: [String: String] = [:]
        for (key, value) in json {
            if let entry = value as? [String: Any], let message = entry["message"] as? String {
                out[key] = message
            }
        }
        return (out, WebExtensionLocalizer.extractPlaceholders(fromMessagesJSON: json))
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

    /// Our in-memory IndexedDB engine (the same one the background worker gets via BrownBearIDBStore),
    /// wrapped in a guard so it installs ONLY when the page origin has no working `indexedDB` — WKWebView
    /// gives the chrome-extension:// custom-scheme page origin none, so a page's `indexedDB.open(...)`
    /// throws "IndexedDB API missing" or hangs (Momentum's Dexie, ScriptCat, …). The engine self-installs
    /// `globalThis.indexedDB`; the guard never overrides a real, working IndexedDB. In-memory per page load
    /// (native-backed persistence is a follow-up).
    private static let idbPolyfillSource: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-indexeddb", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-indexeddb", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* brownbear-indexeddb.js missing */"
        }
        return "(function(){try{if(self.indexedDB&&typeof self.indexedDB.open==='function'){return;}}catch(e){}\n"
            + source + "\n})();"
    }()

    /// The snapshot/persist layer (brownbear-idb-persist.js) — wraps the in-memory engine's write methods to
    /// hand native a debounced JSON snapshot via `__bb_idb_save`, and exposes `__bbIDBRestore`/`__bbIDBFlush`.
    /// The same layer the headless worker gets through `BrownBearIDBStore`; here it's wired to the page.
    private static let idbPersistSource: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-idb-persist", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-idb-persist", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* brownbear-idb-persist.js missing */"
        }
        return source
    }()

    /// Opt-in flag: persist an extension page's IndexedDB across reloads. Default OFF (see makeConfiguration).
    static var persistPageIDBEnabled: Bool { UserDefaults.standard.bool(forKey: "bbPersistExtPageIDB") }

    /// Wire on-disk IndexedDB persistence for one extension page into its content controller, in the slot
    /// AFTER the engine and BEFORE the page bootstrap: (1) a `__bb_idb_save` shim that posts the debounced
    /// snapshot to a native message handler → `BrownBearIDBStore` under the `.extPage` namespace; (2) the
    /// persist layer (it wraps the engine's writes + defines `__bbIDBRestore`); (3) a replay of the last
    /// snapshot so the page sees its prior data before its own scripts open the DB. All `try`-guarded.
    static func installPageIDBPersistence(into controller: WKUserContentController, extensionID: String) {
        let handlerName = "bbExtPageIdbSave"
        controller.add(PageIDBSaveHandler(extensionID: extensionID),
                       contentWorld: WKContentWorld.page, name: handlerName)
        let saveShim = "window.__bb_idb_save=function(j){"
            + "try{window.webkit.messageHandlers.\(handlerName).postMessage(j);}catch(e){}};"
        controller.addUserScript(WKUserScript(source: saveShim,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: idbPersistSource,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Replay the last snapshot, if any, embedded as a JS string literal (fragmentsAllowed escapes it).
        if let snapshot = BrownBearIDBStore.shared.load(namespace: .extPage(extensionID)), !snapshot.isEmpty,
           let literal = (try? JSONSerialization.data(withJSONObject: snapshot, options: .fragmentsAllowed))
            .flatMap({ String(data: $0, encoding: .utf8) }) {
            controller.addUserScript(WKUserScript(
                source: "try{__bbIDBRestore(\(literal));}catch(e){}",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    /// Wire native-backed `window.localStorage` persistence for one extension page into its content
    /// controller, in the slot BEFORE the page runtime (which installs the Storage polyfill): (1) a
    /// `__bb_ls_save` shim posting the page's debounced snapshot to a native message handler →
    /// `BrownBearPageLocalStorageStore` keyed by extension id; (2) a seed of the last snapshot as a
    /// document-start literal (`window.__bb_ls_seed`), so the polyfill's first synchronous read already
    /// sees prior writes. The seed is the saved JSON re-encoded as a string literal and JSON.parsed in the
    /// page (never raw JS source — the value is page-controlled). All `try`-guarded → degrades to in-memory.
    static func installPageLocalStoragePersistence(into controller: WKUserContentController, extensionID: String) {
        let handlerName = "bbExtPageLocalStorageSave"
        controller.add(PageLocalStorageSaveHandler(extensionID: extensionID),
                       contentWorld: WKContentWorld.page, name: handlerName)
        let saveShim = "window.__bb_ls_save=function(j){"
            + "try{window.webkit.messageHandlers.\(handlerName).postMessage(j);}catch(e){}};"
        controller.addUserScript(WKUserScript(source: saveShim,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let snapshot = BrownBearPageLocalStorageStore.shared.load(extensionID: extensionID), !snapshot.isEmpty,
           let literal = (try? JSONSerialization.data(withJSONObject: snapshot, options: .fragmentsAllowed))
            .flatMap({ String(data: $0, encoding: .utf8) }) {
            controller.addUserScript(WKUserScript(
                source: "try{window.__bb_ls_seed=JSON.parse(\(literal));}catch(e){}",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    /// The requestIdleCallback/cancelIdleCallback polyfill. Extension pages (popup/options/dashboard) run
    /// in their own WKWebView config — NOT the shared content controller — so they need their own copy, or
    /// a page that calls requestIdleCallback during init (uBlock Origin Lite's dashboard does) throws a bare
    /// ReferenceError and renders blank. Same shim the page + content worlds get via InjectionOrchestrator.
    static let idlePolyfillSource: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-idle-callback", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-idle-callback", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* brownbear-idle-callback.js missing */"
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
        case .options, .newtab: contextType = "TAB"
        case .offscreen: contextType = "OFFSCREEN_DOCUMENT"
        case .sidebar: contextType = "SIDE_PANEL"
        }
        // An offscreen document isn't associated with a top frame or a window — Chrome reports
        // frameId/windowId as -1 for it (unlike a popup/options page, which lives in the lone window).
        let isOffscreen = kind == .offscreen
        return [
            "contextId": pageToken,
            "contextType": contextType,
            "documentId": pageToken,
            "documentUrl": pageURL?.absoluteString ?? NSNull(),
            "documentOrigin": "\(ext.scheme)://\(ext.id)",
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

/// Receives an extension page's debounced IndexedDB snapshot (`__bb_idb_save` → message handler) and
/// persists it under its `.extPage` namespace. Holds only the extension id (no view/session reference), so
/// the controller's strong retention of it can't form a cycle. The store write is thread-safe + off-queue.
@MainActor
final class PageIDBSaveHandler: NSObject, WKScriptMessageHandler {
    private let extensionID: String
    init(extensionID: String) { self.extensionID = extensionID }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String, !json.isEmpty else { return }
        BrownBearIDBStore.shared.save(json, namespace: .extPage(extensionID))
    }
}
