//
//  WebExtensionMessageRouter.swift
//  BrownBear
//
//  The native side of the extension runtime. It answers getContentScripts (which extensions'
//  content scripts match this URL, with their JS/CSS/manifest/i18n) and the chrome.storage.*
//  calls, with the same native-bound-token identity model as the userscript bridge so one
//  extension's storage stays isolated from another's.
//
//  Messaging (Module 6 Phase 3): each content-script injection registers a session that remembers the
//  exact web view + frame it runs in, so the runtime can push chrome.tabs.sendMessage payloads and
//  chrome.storage.onChanged changes back INTO the content script and correlate its async response. A
//  popup/background worker runs its own router with no content sessions, so its tabs.sendMessage is
//  delegated through the bridge host to whichever router owns the target tab's content sessions.
//

import WebKit

@MainActor
final class WebExtensionMessageRouter: NSObject, WKScriptMessageHandlerWithReply {

    static let handlerName = "brownbearWebext"

    /// What a token resolves to: the extension it belongs to, and (for a content script) the exact web
    /// view + frame it runs in so the runtime can push messages/changes back into it. `webView` is weak
    /// so a token can't pin a closed tab; a popup/options page session has no web view (isContent=false).
    private struct Session {
        let extensionID: String
        let isContent: Bool
        weak var webView: WKWebView?
        var frameInfo: WKFrameInfo?
        /// chrome.runtime.MessageSender.frameId — 0 for the main frame, a minted positive int per
        /// subframe. Identifies the frame the content script runs in for the receiver's reply routing.
        var frameId: Int = 0
        /// chrome.runtime.MessageSender.documentId — a stable per-document id (one per frame load),
        /// shared by every content script injected into that document, matching Chrome.
        var documentId: String = ""
    }

    let store: WebExtensionStore   // internal: the +ContextMenus / +Ports extension files reach it
    private let storage: WebExtensionStorage
    private let runtime: WebExtensionRuntime
    /// The world content scripts (and thus their __bbExtContent push targets) live in. Pushes are
    /// evaluated into this world so they reach the content script's closure, not the page.
    private let contentWorld: WKContentWorld
    /// Lets chrome.tabs reach the browser's TabManager. Set via InjectionOrchestrator.
    weak var host: WebExtensionBridgeHost?
    /// Lets chrome.cookies reach the browser's WKHTTPCookieStore. Set via InjectionOrchestrator.
    weak var cookieHost: WebExtensionCookieBridgeHost?
    /// token → session. Minted per content-script injection / page.
    private var sessions: [String: Session] = [:]
    /// Insertion order of tokens, for FIFO eviction once `sessions` exceeds `maxSessions`.
    private var tokenOrder: [String] = []
    /// Monotonic source of MessageSender.frameId for subframes (the main frame is always 0).
    private var frameIdCounter = 0
    /// Correlates a native→content message push with the content script's eventual sendResponse.
    private let responseTable = WebExtContentResponseTable()
    private var storageObserver: NSObjectProtocol?

    /// How long a pushed message waits for the content script's sendResponse before resolving nil, so a
    /// listener that returns `true` then never answers can't strand the awaiting sender forever.
    private static let responseTimeout: UInt64 = 30 * 1_000_000_000

    init(store: WebExtensionStore, storage: WebExtensionStorage, runtime: WebExtensionRuntime,
         contentWorld: WKContentWorld) {
        self.store = store
        self.storage = storage
        self.runtime = runtime
        self.contentWorld = contentWorld
        super.init()
        // Fan chrome.storage changes out to this router's live content scripts (the background worker
        // and any open popup observe the same notification through their own surfaces).
        storageObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionStorageDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleStorageChange(note) }
        }
    }

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    /// Mint a token bound to `extensionID` for an extension PAGE (popup/options). The page's chrome.*
    /// surface carries this token so its storage/runtime calls resolve to the right extension — the
    /// same native-bound identity model content scripts use.
    func makePageSession(for extensionID: String) -> String {
        let token = UUID().uuidString
        registerSession(token: token, session: Session(extensionID: extensionID, isContent: false))
        return token
    }

    /// Attach the page's web view to a page session after the WKWebView is created (makePageSession runs
    /// before the view exists). Lets the runtime push chrome.runtime.connect port traffic INTO an open
    /// popup/options page, which needs the exact web view to evaluate into.
    func attachPageWebView(token: String, webView: WKWebView) {
        guard var session = sessions[token] else { return }
        session.webView = webView
        sessions[token] = session
    }

    /// The web view + frame + content-vs-page kind a `token`'s session evaluates into, or nil if the
    /// session is gone or has no live web view. Used by the +Ports extension (separate file, which
    /// can't see the private `sessions`/`Session`) to deliver port callbacks. Internal, not public.
    func portDeliveryTarget(token: String) -> (webView: WKWebView, frame: WKFrameInfo?, isContent: Bool)? {
        guard let session = sessions[token], let webView = session.webView else { return nil }
        return (webView, session.frameInfo, session.isContent)
    }

    /// The router's isolated content world (content endpoints) — exposed for the +Ports extension, which
    /// evaluates into the same world the content scripts / page surface live in.
    var portContentWorld: WKContentWorld { contentWorld }

    /// JSON-encode a value for embedding in evaluated JS — the same fragment-allowed encoding the
    /// in-file pushes use, exposed so the +Ports extension can build its port-push argument literals.
    static func encodeJSONForJS(_ value: Any) -> String { jsonString(value) }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let api = body["api"] as? String else {
            replyHandler(nil, "malformed extension bridge message")
            return
        }
        let payload = body["payload"] as? [String: Any] ?? [:]
        let token = body["token"] as? String
        // The web view + frame are the linchpin for messaging: getContentScripts records them on each
        // session so the runtime can later address that exact content script.
        let webView = message.webView
        let frameInfo = message.frameInfo

        Task { @MainActor in
            do {
                let result = try await self.route(api: api, payload: payload, token: token,
                                                  webView: webView, frameInfo: frameInfo)
                replyHandler(result, nil)
            } catch let error as BrownBearError {
                let msg = error.errorDescription ?? "extension bridge error"
                await self.logBridgeError(api: api, token: token, message: msg)
                replyHandler(nil, msg)
            } catch {
                await self.logBridgeError(api: api, token: token, message: error.localizedDescription)
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    /// Surface a routed chrome.* failure to the Logs tab. Every chrome.* call funnels through route(); a
    /// thrown failure was previously returned ONLY to the JS promise, so an extension that fire-and-forgets
    /// or omits .catch (most chrome.* calls) lost the error with zero Logs signal. Best-effort attribution:
    /// resolve the extension from the token (nil/stale token → unattributed engine line).
    private func logBridgeError(api: String, token: String?, message: String) async {
        // Non-mutating token→extension lookup (resolve() would evict a disabled session as a side effect).
        let extensionID = token.flatMap { sessions[$0]?.extensionID } ?? ""
        await runtime.logFromPage(extensionID: extensionID,
                                  level: "error", message: "chrome.\(api) failed: \(message)")
    }

    // MARK: - Routing

    private func route(api: String, payload: [String: Any], token: String?,
                       webView: WKWebView?, frameInfo: WKFrameInfo?) async throws -> Any? {
        if api == "getContentScripts" {
            return try await handleGetContentScripts(payload: payload, webView: webView, frameInfo: frameInfo)
        }
        // MV3 world:"MAIN" injection (ScriptCat's inject.js + the cross-world bridge shim) evaluated in the
        // page's REAL main world via native evaluateJavaScript — which, unlike an inline <script> element,
        // is NOT subject to the page's CSP, so managers run on hardened sites too. No grant needed: this
        // handler is registered ONLY in our isolated content world, so a page script can't reach it; the
        // sending web view/frame is the trust anchor. Targets the requesting frame's page world.
        if api == "page.injectMainWorld" {
            if let webView, let code = payload["code"] as? String, !code.isEmpty {
                if let frameInfo {
                    BBEvaluateJavaScriptInFrame(webView, code, frameInfo, .page)
                } else {
                    BBEvaluateJavaScript(webView, code, .page)
                }
            }
            return NSNull()
        }
        // Tokenless frame-level diagnostic (the content-script loader uses token=null and resolve() would
        // throw on it). The loader aborting means NO content scripts inject for the frame — a total, silent
        // failure — so route it here, before resolve(token), to make it visible in the Logs.
        if api == "runtime.frameLog" {
            await runtime.logFromPage(extensionID: "", level: payload["level"] as? String ?? "info",
                                      message: payload["message"] as? String ?? "")
            return NSNull()
        }
        // A content script answering a pushed message. No grant needed — it only resumes a continuation
        // the runtime itself parked, keyed by an unguessable id, and is a no-op for an unknown id.
        if api == "runtime.messageResponse" {
            if let responseId = payload["responseId"] as? String {
                responseTable.resolve(responseId, value: payload["value"])
            }
            return NSNull()
        }

        // chrome.runtime.connect/onConnect long-lived ports. Resolved against the token (so the port is
        // bound to the right extension + endpoint) but otherwise relayed opaquely by the port hub.
        if api == "port.connect" || api == "port.postMessage" || api == "port.disconnect" {
            return try await routePort(api: api, payload: payload, token: token)
        }

        let extensionID = try await resolve(token)
        let area = WebExtensionStorage.Area(rawValue: (payload["area"] as? String) ?? "local") ?? .local

        // A popup/options page forwarding its own console / uncaught errors. No grant needed — it only
        // writes a log line scoped to this extension, so its blank-page failures are diagnosable.
        if api == "runtime.pageLog" {
            await runtime.logFromPage(extensionID: extensionID,
                                      level: (payload["level"] as? String) ?? "info",
                                      message: (payload["message"] as? String) ?? "")
            return NSNull()
        }

        switch api {
        case "storage.get":
            let keys = payload["keys"] as? [String]   // nil = all
            return await storage.get(extensionID: extensionID, area: area, keys: keys)

        case "storage.set":
            guard let items = payload["items"] as? [String: String] else {
                throw BrownBearError.bridgeRejected("storage.set missing items")
            }
            await storage.set(extensionID: extensionID, area: area, items: items)
            return NSNull()

        case "storage.remove":
            let keys = payload["keys"] as? [String] ?? []
            await storage.remove(extensionID: extensionID, area: area, keys: keys)
            return NSNull()

        case "storage.clear":
            await storage.clear(extensionID: extensionID, area: area)
            return NSNull()

        case "runtime.sendMessage":
            // Content script / page → its extension's other contexts (background worker + open pages).
            // `message` is any JSON. `token` (the sender) is passed so a page never gets its own message.
            // The sender carries the full Chrome MessageSender shape so a background listener can reply
            // via chrome.tabs.sendMessage(sender.tab.id, …) — see buildMessageSender.
            let message = payload["message"] ?? NSNull()
            let sender = buildMessageSender(token: token, extensionID: extensionID,
                                            url: payload["url"] as? String, webView: webView, frameInfo: frameInfo)
            guard let response = await runtime.sendRuntimeMessage(message, sender: sender,
                                                                  to: extensionID, senderToken: token) else {
                return NSNull()
            }
            return response

        case "runtime.userScriptMessage":
            // A USER_SCRIPT-world script (configureWorld({messaging:true})) → the worker's
            // chrome.runtime.onUserScriptMessage (NOT onMessage). Only the background worker receives it.
            let message = payload["message"] ?? NSNull()
            let sender = buildMessageSender(token: token, extensionID: extensionID,
                                            url: payload["url"] as? String, webView: webView, frameInfo: frameInfo)
            return await runtime.deliverUserScriptMessage(extensionID: extensionID, message: message, sender: sender)
                ?? NSNull()

        case "runtime.openOptionsPage":
            guard let host, await store.ext(for: extensionID)?.manifest?.optionsPage != nil else {
                throw BrownBearError.bridgeRejected("no options page to open")
            }
            _ = host.webExtOpenOptionsPage(extensionID: extensionID)
            return NSNull()

        case "windows.get", "windows.getCurrent", "windows.getLastFocused", "windows.getAll",
             "windows.create", "windows.update", "windows.remove",
             "management.getAll", "management.get", "management.getSelf",
             "permissions.getAll", "permissions.contains", "permissions.request", "permissions.remove",
             "runtime.setUninstallURL", "runtime.getPlatformInfo":
            return try await routeWindowsManagementPermissions(api: api, payload: payload, extensionID: extensionID)

        // chrome.cookies — gated on the `cookies` API permission plus a host_permission covering the
        // target (reads/writes); getAllCookieStores needs only the cookies permission. The browser's
        // WKHTTPCookieStore is reached through the bridge host.
        case "cookies.get", "cookies.getAll", "cookies.set", "cookies.remove", "cookies.getAllCookieStores":
            return try await routeCookies(api: api, payload: payload, extensionID: extensionID)

        case "notifications.create", "notifications.update", "notifications.clear", "notifications.getAll":
            return try await routeNotifications(api: api, payload: payload, extensionID: extensionID)

        case "action.setBadgeText", "action.setBadgeBackgroundColor", "action.setTitle", "action.setPopup",
             "action.setIcon", "action.enable", "action.disable",
             "action.getBadgeText", "action.getTitle", "action.getBadgeBackgroundColor":
            return routeAction(api: api, payload: payload, extensionID: extensionID)

        case "contextMenus.create", "contextMenus.update", "contextMenus.remove", "contextMenus.removeAll",
             "menus.create", "menus.update", "menus.remove", "menus.removeAll":
            return try await routeContextMenus(api: api, payload: payload, extensionID: extensionID)

        case "dnr.updateDynamicRules", "dnr.updateSessionRules", "dnr.updateEnabledRulesets",
             "dnr.getDynamicRules", "dnr.getSessionRules", "dnr.getEnabledRulesets",
             "userScripts.register", "userScripts.update", "userScripts.getScripts",
             "userScripts.unregister", "userScripts.configureWorld":
            return try await routeDNRUserScripts(api: api, payload: payload, extensionID: extensionID)

        // Privileged extension-page fetch: a page may reach a host in its host_permissions without CORS
        // (Chrome's extension-page network path). Host-gated; a non-declared host reports notPermitted so
        // the page falls back to a normal (CORS) fetch.
        case "hostFetch":
            return await routeHostFetch(payload: payload, extensionID: extensionID)

        default:
            guard let result = await routeTabsAndScripting(api: api, payload: payload, extensionID: extensionID) else {
                throw BrownBearError.bridgeRejected("unsupported extension api '\(api)'")
            }
            return result
        }
    }

    /// chrome.tabs + chrome.scripting routing — driven through the browser's TabManager via the bridge
    /// host. A thin dispatcher over `routeTabs`/`routeScripting` so each switch stays well under the
    /// complexity limit. Returns nil for an api neither handles (route() then rejects it). A valid
    /// extension token is already resolved by route().
    private func routeTabsAndScripting(api: String, payload: [String: Any], extensionID: String) async -> Any? {
        if let result = await routeTabs(api: api, payload: payload, extensionID: extensionID) { return result }
        return await routeScripting(api: api, payload: payload, extensionID: extensionID)
    }

    /// chrome.tabs.* (excluding the MV2 executeScript/insertCSS, which routeScripting owns). Returns nil
    /// for an api it doesn't handle. Handled cases always return a non-nil value (NSNull() for void).
    private func routeTabs(api: String, payload: [String: Any], extensionID: String) async -> Any? {
        switch api {
        case "tabs.query":
            guard let host else { return [] }
            return host.webExtQueryTabs(payload["query"] as? [String: Any] ?? [:])

        case "tabs.get":
            guard let host else { return NSNull() }
            return host.webExtTab(extTabId: payload["tabId"] as? Int) ?? NSNull()

        case "tabs.getCurrent":
            return NSNull()   // meaningful only for an extension's own full-page tab (none on iOS)

        case "tabs.create":
            guard let host else { return NSNull() }
            return host.webExtCreateTab(url: payload["url"] as? String,
                                        active: (payload["active"] as? Bool) ?? true)

        case "tabs.update":
            guard let host else { return NSNull() }
            return host.webExtUpdateTab(extTabId: payload["tabId"] as? Int,
                                        url: payload["url"] as? String,
                                        active: payload["active"] as? Bool) ?? NSNull()

        case "tabs.remove":
            guard let host else { return NSNull() }
            let ids = (payload["tabIds"] as? [Int]) ?? (payload["tabId"] as? Int).map { [$0] } ?? []
            host.webExtRemoveTabs(extTabIds: ids)
            return NSNull()

        case "tabs.reload":
            guard let host else { return NSNull() }
            host.webExtReloadTab(extTabId: payload["tabId"] as? Int,
                                 bypassCache: (payload["bypassCache"] as? Bool) ?? false)
            return NSNull()

        case "tabs.move":
            guard let host else { return [] }
            let ids = (payload["tabIds"] as? [Int]) ?? (payload["tabId"] as? Int).map { [$0] } ?? []
            return host.webExtMoveTabs(extTabIds: ids, index: (payload["index"] as? Int) ?? -1)

        case "tabs.duplicate":
            guard let host, let tabId = payload["tabId"] as? Int else { return NSNull() }
            return host.webExtDuplicateTab(extTabId: tabId) ?? NSNull()

        case "tabs.getZoom":
            guard let host else { return 1.0 }
            return host.webExtGetZoom(extTabId: payload["tabId"] as? Int)

        case "tabs.setZoom":
            guard let host else { return NSNull() }
            host.webExtSetZoom(extTabId: payload["tabId"] as? Int,
                               factor: (payload["zoomFactor"] as? Double) ?? 0)
            return NSNull()

        case "tabs.sendMessage":
            // Deliver to the target tab's content scripts. Always via the bridge host, because the
            // content sessions may live on a DIFFERENT router instance (this call may originate from a
            // popup whose own router has no content sessions). The host routes to the owning router.
            guard let host else { return NSNull() }
            let response = await host.webExtSendMessageToTab(extensionID: extensionID,
                                                             extTabId: payload["tabId"] as? Int,
                                                             message: payload["message"] ?? NSNull(),
                                                             frameId: payload["frameId"] as? Int)
            return response ?? NSNull()

        case "tabs.captureVisibleTab":
            // A popup/options page capturing the visible tab (a screenshot extension's GoFullPage does
            // this from its popup). Page pixels are sensitive (§5): honor "activeTab" for the active tab
            // — the popup is opened by the user invoking the action, which IS the activeTab gesture —
            // otherwise require a host_permissions match for the captured tab (same fail-closed gate as
            // the background __bb_capture_visible_tab path). The gate runs INSIDE the host against the
            // captured tab's URL, so a tab switch can't bypass it.
            guard let host else { return NSNull() }
            let manifest = await store.ext(for: extensionID)?.manifest
            let hasActiveTab = manifest?.permissions.contains("activeTab") ?? false
            let allUrls = manifest?.hostPermissions.contains("<all_urls>") ?? false
            let matcher = URLMatcher(matches: manifest?.hostPermissions ?? [],
                                     includes: [], excludes: [], excludeMatches: [])
            let dataURL = await host.webExtCaptureVisibleTab(format: (payload["format"] as? String) ?? "png",
                                                             quality: (payload["quality"] as? Int) ?? 92) { url in
                hasActiveTab || allUrls || (url.map { matcher.matches($0) } ?? false)
            }
            if let dataURL { return dataURL }
            return NSNull()

        default:
            return nil
        }
    }

    /// chrome.scripting (MV3) + chrome.tabs.executeScript/insertCSS (MV2). `func`/`args` are serialized
    /// to `code` by the JS shim; `files` are read from the extension's own package here. Returns nil for
    /// an api it doesn't handle.
    private func routeScripting(api: String, payload: [String: Any], extensionID: String) async -> Any? {
        switch api {
        case "scripting.executeScript":
            guard let host else { return [] }
            let target = payload["target"] as? [String: Any] ?? [:]
            let tabId = target["tabId"] as? Int
            guard await canInjectIntoTab(extensionID: extensionID, isMV3: true, extTabId: tabId) else { return [] }
            let code = await resolveInjectedCode(payload: payload, extensionID: extensionID, separator: "\n;\n")
            guard !code.isEmpty else { return [] }
            return await host.webExtExecuteScript(extTabId: tabId,
                                                  world: (payload["world"] as? String) ?? "ISOLATED", code: code)

        case "scripting.insertCSS", "scripting.removeCSS":
            guard let host else { return NSNull() }
            let target = payload["target"] as? [String: Any] ?? [:]
            let tabId = target["tabId"] as? Int
            guard await canInjectIntoTab(extensionID: extensionID, isMV3: true, extTabId: tabId) else { return NSNull() }
            let css = await resolveInjectedCSS(payload: payload, extensionID: extensionID)
            if api == "scripting.insertCSS" {
                host.webExtInsertCSS(extTabId: tabId, css: css)
            } else {
                host.webExtRemoveCSS(extTabId: tabId, css: css)
            }
            return NSNull()

        case "tabs.executeScript":
            guard let host else { return [] }
            let tabId = payload["tabId"] as? Int
            guard await canInjectIntoTab(extensionID: extensionID, isMV3: false, extTabId: tabId) else { return [] }
            var code = payload["code"] as? String ?? ""
            if code.isEmpty, let file = payload["file"] as? String,
               let text = await store.text(extensionID: extensionID, path: file) { code = text }
            guard !code.isEmpty else { return [] }
            let results = await host.webExtExecuteScript(extTabId: tabId,
                                                         world: (payload["world"] as? String) ?? "ISOLATED", code: code)
            return results.map { $0["result"] ?? NSNull() }   // MV2 returns the raw results array

        case "tabs.insertCSS":
            guard let host else { return NSNull() }
            let tabId = payload["tabId"] as? Int
            guard await canInjectIntoTab(extensionID: extensionID, isMV3: false, extTabId: tabId) else { return NSNull() }
            var css = payload["code"] as? String ?? ""
            if css.isEmpty, let file = payload["file"] as? String,
               let text = await store.text(extensionID: extensionID, path: file) { css = text }
            host.webExtInsertCSS(extTabId: tabId, css: css)
            return NSNull()

        default:
            return nil
        }
    }

    // MARK: - Messaging push (native → content script)

    /// chrome.tabs.sendMessage delivery to the content scripts of `extensionID` in `webView`. Pushes
    /// the message into each matching content session and resolves with the first non-null response
    /// (chrome resolves sendMessage with the first listener that answers). Returns nil if the tab has
    /// no content sessions for this extension. Called via the bridge host from any surface's router.
    func sendMessageToTab(extensionID: String, webView: WKWebView, message: Any, frameId: Int?) async -> Any? {
        let targets = sessions.filter { _, session in
            session.isContent && session.extensionID == extensionID && session.webView === webView
        }
        guard !targets.isEmpty else { return nil }
        // A tabs.sendMessage push originates from the extension itself (background/popup), which is NOT a
        // tab — so the content script's onMessage sender carries the extension id + origin and no `tab`.
        let sender: [String: Any] = ["id": extensionID, "origin": "chrome-extension://\(extensionID)"]
        for (token, session) in targets {
            let response = await pushMessage(token: token, webView: webView, frame: session.frameInfo,
                                             message: message, sender: sender)
            if let response, !(response is NSNull) { return response }
        }
        return nil
    }

    /// Push one message into the content script registered under `token` and await its sendResponse.
    private func pushMessage(token: String, webView: WKWebView, frame: WKFrameInfo?,
                             message: Any, sender: [String: Any]) async -> Any? {
        await responseTable.wait { responseId in
            let js = "window.__bbExtContent&&window.__bbExtContent['\(token)']&&"
                + "window.__bbExtContent['\(token)'].onMessage("
                + "\(Self.jsonString(message)),\(Self.jsonString(sender)),'\(responseId)');"
            // Into the EXACT frame this content script runs in, in the isolated content world.
            BBEvaluateJavaScriptInFrame(webView, js, frame, contentWorld)
            self.schedulePushTimeout(responseId)
        }
    }

    private func schedulePushTimeout(_ responseId: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.responseTimeout)
            self.responseTable.resolve(responseId, value: nil)
        }
    }

    /// Deliver a runtime message INTO an open extension PAGE (popup/options) registered under `token`
    /// and await its chrome.runtime.onMessage sendResponse. Returns `["value": ...]` for an answer,
    /// nil if the page has no live web view or no listener answered. The page uses this same router, so
    /// its sendResponse (bridge "runtime.messageResponse") resolves the responseTable. Called by the
    /// page session when the runtime fans a runtime.sendMessage out to open pages.
    func deliverRuntimeMessageToPage(token: String, message: Any, sender: [String: Any]) async -> [String: Any]? {
        guard let session = sessions[token], !session.isContent, let webView = session.webView else { return nil }
        let response = await pushMessageToPage(webView: webView, message: message, sender: sender)
        if let response, !(response is NSNull) { return ["value": response] }
        return nil
    }

    /// Push one message into an extension page's chrome.runtime.onMessage and await its sendResponse.
    private func pushMessageToPage(webView: WKWebView, message: Any, sender: [String: Any]) async -> Any? {
        await responseTable.wait { responseId in
            let js = "window.__brownbearExtPage&&window.__brownbearExtPage.dispatchMessage("
                + "\(Self.jsonString(message)),\(Self.jsonString(sender)),'\(responseId)');"
            BBEvaluateJavaScript(webView, js, contentWorld)   // ObjC shim — main frame, page world.
            self.schedulePushTimeout(responseId)
        }
    }

    // MARK: - storage.onChanged push (native → content script)

    private func handleStorageChange(_ note: Notification) {
        guard let info = note.userInfo,
              let extensionID = info["extensionID"] as? String,
              let area = info["area"] as? String,
              let changes = info["changes"] as? [String: [String: String]] else { return }
        let changesJSON = Self.jsonString(changes)
        let areaJSON = Self.jsonString(area)
        for (token, session) in sessions where session.isContent && session.extensionID == extensionID {
            guard let webView = session.webView else { continue }
            let js = "window.__bbExtContent&&window.__bbExtContent['\(token)']&&"
                + "window.__bbExtContent['\(token)'].onStorageChanged(\(changesJSON),\(areaJSON));"
            BBEvaluateJavaScriptInFrame(webView, js, session.frameInfo, contentWorld)
        }
    }

    // MARK: - JS shim helpers

    private func resolveInjectedCode(payload: [String: Any], extensionID: String, separator: String) async -> String {
        if let code = payload["code"] as? String, !code.isEmpty { return code }
        var out = ""
        for path in (payload["files"] as? [String] ?? []) {
            if let text = await store.text(extensionID: extensionID, path: path) { out += text + separator }
        }
        return out
    }

    /// The CSS for chrome.scripting.insertCSS/removeCSS: an explicit `css` string, else `files`.
    private func resolveInjectedCSS(payload: [String: Any], extensionID: String) async -> String {
        if let css = payload["css"] as? String, !css.isEmpty { return css }
        var out = ""
        for path in (payload["files"] as? [String] ?? []) {
            if let text = await store.text(extensionID: extensionID, path: path) { out += text + "\n" }
        }
        return out
    }

    /// Serialize a value to a JSON literal for embedding in evaluated JS. Fragments allowed so a bare
    /// string/number/bool message round-trips. Sanitizes NaN/Infinity (which would otherwise throw an
    /// uncatchable Obj-C exception in JSONSerialization) and falls back to `null` — fail closed.
    private static func jsonString(_ value: Any) -> String {
        JSONSanitize.string(value)
    }

    // MARK: - Identity / sessions

    /// Internal alias for `resolve(_:)` so the +Ports extension (separate file) can resolve a token to
    /// its extension id — the same fail-closed identity check every routed call uses.
    func resolveExtensionID(_ token: String?) async throws -> String { try await resolve(token) }

    // MARK: - chrome.runtime.MessageSender

    /// Build the MessageSender for a runtime.sendMessage from `token`'s context. A content script (a
    /// session bound to a real browser tab) gets the full Chrome shape — `tab` so the receiver can reply
    /// via chrome.tabs.sendMessage(sender.tab.id, …), plus `frameId`/`documentId`/`url`/`origin`. A
    /// popup/options page omits `tab` (Chrome attaches `tab` iff the sender runs in a tab). `webView`/
    /// `frameInfo` are the live message's; the session supplies the stable per-document frameId/docId.
    private func buildMessageSender(token: String?, extensionID: String, url: String?,
                                    webView: WKWebView?, frameInfo: WKFrameInfo?) -> [String: Any] {
        let session = token.flatMap { sessions[$0] }
        let tabRecord = webView.flatMap { host?.webExtTabRecord(forWebView: $0) }
        let frameId = session?.frameId ?? ((frameInfo?.isMainFrame ?? true) ? 0 : 0)
        return Self.assembleSender(extensionID: extensionID, url: url, tabRecord: tabRecord,
                                   frameId: frameId, documentId: session?.documentId)
    }

    /// Pure assembly of a chrome.runtime.MessageSender from already-resolved parts (no host/web view) —
    /// unit-testable. `tabRecord` is non-nil iff the sender runs in a browser tab, in which case `tab`,
    /// `frameId`, and `documentId` are attached; a page sender passes nil and gets none of them. The
    /// `origin` is derived from `url` (Chrome includes it whenever the sender has a web origin).
    static func assembleSender(extensionID: String, url: String?, tabRecord: [String: Any]?,
                               frameId: Int, documentId: String?) -> [String: Any] {
        var sender: [String: Any] = ["id": extensionID]
        if let url, !url.isEmpty {
            sender["url"] = url
            if let origin = origin(ofURLString: url) { sender["origin"] = origin }
        }
        if let tabRecord {
            sender["tab"] = tabRecord
            sender["frameId"] = frameId
            if let documentId, !documentId.isEmpty { sender["documentId"] = documentId }
        }
        return sender
    }

    /// The web origin (scheme://host[:port]) of a URL string, or nil for an origin-less URL
    /// (e.g. about:blank, data:). Mirrors the `origin` field Chrome puts on a MessageSender.
    static func origin(ofURLString string: String) -> String? {
        guard let url = URL(string: string), let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// frameId for a freshly-loaded frame: 0 for the main frame, a minted positive int per subframe.
    private func mintFrameId(isMainFrame: Bool) -> Int {
        guard !isMainFrame else { return 0 }
        frameIdCounter += 1
        return frameIdCounter
    }

    /// A fresh per-document id (32 lowercase hex chars, Chrome's documentId shape).
    private static func newDocumentId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func resolve(_ token: String?) async throws -> String {
        guard let token, let session = sessions[token] else {
            throw BrownBearError.bridgeRejected("unrecognized extension token")
        }
        let extensionID = session.extensionID
        // Fail closed if the extension was disabled/removed after this token was minted — otherwise
        // an already-injected content script keeps read/write access to storage until it navigates.
        guard await store.ext(for: extensionID)?.enabled == true else {
            sessions.removeValue(forKey: token)
            throw BrownBearError.bridgeRejected("extension is disabled")
        }
        return extensionID
    }

    /// token → session, with a FIFO cap so the map can't grow unbounded across a long session of
    /// navigations. Prefer evicting a DEAD content session (its web view deallocated) so the cap can't
    /// sever a live content script's identity mid-run.
    private static let maxSessions = 2000
    private func registerSession(token: String, session: Session) {
        sessions[token] = session
        tokenOrder.append(token)
        guard tokenOrder.count > Self.maxSessions else { return }
        if let deadIndex = tokenOrder.firstIndex(where: { key in
            guard let session = sessions[key] else { return true }
            return session.isContent && session.webView == nil
        }) {
            let evicted = tokenOrder.remove(at: deadIndex)
            sessions.removeValue(forKey: evicted)
        } else {
            let evicted = tokenOrder.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
    }

    /// Drop every content session for a web view — called when its main frame (re)loads so stale tokens
    /// from the prior page (and their defunct frames) don't linger or receive message/storage pushes.
    private func purgeSessions(for webView: WKWebView) {
        let stale = sessions.compactMap { key, session in
            (session.isContent && session.webView === webView) ? key : nil
        }
        guard !stale.isEmpty else { return }
        for token in stale { sessions.removeValue(forKey: token) }
        let staleSet = Set(stale)
        tokenOrder.removeAll { staleSet.contains($0) }
        // The purged content scripts may have held open chrome.runtime ports; tear those down so their
        // background-worker peers get onDisconnect rather than stranding a listener on a dead frame.
        BrownBearServices.shared.webExtensionRuntime.portHub.disconnectClientPorts(tokens: staleSet)
    }

}

// MARK: - getContentScripts (split into an extension to keep the class body under type_body_length)

extension WebExtensionMessageRouter {

    private func handleGetContentScripts(payload: [String: Any],
                                         webView: WKWebView?,
                                         frameInfo: WKFrameInfo?) async throws -> [[String: Any]] {
        guard let urlString = payload["url"] as? String else {
            throw BrownBearError.bridgeRejected("missing url")
        }
        let isSubframe = (payload["isSubframe"] as? Bool) ?? false
        // A main-frame load means a new page (or reload) — reap the web view's prior content sessions so
        // they don't accumulate or get targeted by pushes after their frames are gone.
        if !isSubframe, let webView { purgeSessions(for: webView) }
        // One frameId + documentId per frame load: every content script injected into this document
        // shares them (they identify the frame/document, not the script), exactly like Chrome.
        let frameId = mintFrameId(isMainFrame: frameInfo?.isMainFrame ?? !isSubframe)
        let documentId = Self.newDocumentId()
        let extensions = await store.enabledExtensions()
        var result: [[String: Any]] = []

        for ext in extensions {
            guard let manifest = ext.manifest else { continue }
            let messages = await loadMessages(ext, manifest: manifest)
            for contentScript in manifest.contentScripts {
                if isSubframe && !contentScript.allFrames { continue }
                let matcher = URLMatcher(matches: contentScript.matches,
                                         includes: contentScript.includeGlobs,
                                         excludes: contentScript.excludeGlobs,
                                         excludeMatches: contentScript.excludeMatches)
                guard matcher.matches(urlString) else { continue }

                var jsCode = ""
                for path in contentScript.js {
                    if let text = await store.text(extensionID: ext.id, path: path) { jsCode += text + "\n;\n" }
                }
                var cssCode = ""
                for path in contentScript.css {
                    if let text = await store.text(extensionID: ext.id, path: path) { cssCode += text + "\n" }
                }

                let token = UUID().uuidString
                registerSession(token: token,
                                session: Session(extensionID: ext.id, isContent: true,
                                                 webView: webView, frameInfo: frameInfo,
                                                 frameId: frameId, documentId: documentId))
                result.append([
                    "token": token,
                    "extensionId": ext.id,
                    "runAt": contentScript.runAt,
                    "allFrames": contentScript.allFrames,
                    "js": jsCode,
                    "css": cssCode,
                    "manifestJSON": ext.manifestJSON,
                    "baseURL": ext.baseURLString,
                    "messages": messages
                ])
            }

            // chrome.userScripts (MV3): runtime-registered scripts inject like content scripts. They
            // reuse the same per-navigation path + session model, so they get a token and addressable
            // session. `world` selects MAIN (page world) vs our isolated world; `userScriptMessaging`
            // (configureWorld({messaging:true}) on the default world) lets a USER_SCRIPT-world script
            // reach the worker's onUserScriptMessage.
            let usStore = BrownBearServices.shared.webExtensionUserScriptStore
            let userScriptMessaging = await usStore.worldConfigs(extensionID: ext.id)
                .contains { $0.worldId == nil && $0.messaging }
            for userScript in await usStore.getScripts(extensionID: ext.id, ids: nil) {
                if isSubframe && !userScript.allFrames { continue }
                let matcher = URLMatcher(matches: userScript.matches, includes: userScript.includeGlobs,
                                         excludes: userScript.excludeGlobs, excludeMatches: userScript.excludeMatches)
                guard matcher.matches(urlString) else { continue }
                let token = UUID().uuidString
                registerSession(token: token,
                                session: Session(extensionID: ext.id, isContent: true,
                                                 webView: webView, frameInfo: frameInfo,
                                                 frameId: frameId, documentId: documentId))
                result.append([
                    "token": token,
                    "extensionId": ext.id,
                    "runAt": userScript.runAt,
                    "allFrames": userScript.allFrames,
                    "js": userScript.js,
                    "css": "",
                    // `world` drives where the loader runs it: MAIN → the page's real main world (injected
                    // as a <script> element); USER_SCRIPT/ISOLATED → our isolated bridge world. MV3
                    // userScript managers (ScriptCat, Tampermonkey) register page-world scripts as MAIN.
                    "world": userScript.world,
                    "userScriptMessaging": userScriptMessaging,
                    "manifestJSON": ext.manifestJSON,
                    "baseURL": ext.baseURLString,
                    "messages": messages
                ])
            }
        }
        return result
    }

    /// Load the default-locale messages.json (flattened to key → message) for chrome.i18n.
    private func loadMessages(_ ext: WebExtension, manifest: WebExtensionManifest) async -> [String: String] {
        guard let locale = manifest.defaultLocale,
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
}

