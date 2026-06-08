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
                replyHandler(nil, error.errorDescription ?? "extension bridge error")
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Routing

    private func route(api: String, payload: [String: Any], token: String?,
                       webView: WKWebView?, frameInfo: WKFrameInfo?) async throws -> Any? {
        if api == "getContentScripts" {
            return try await handleGetContentScripts(payload: payload, webView: webView, frameInfo: frameInfo)
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
            let message = payload["message"] ?? NSNull()
            var sender: [String: Any] = ["id": extensionID]
            if let url = payload["url"] as? String { sender["url"] = url }
            guard let response = await runtime.sendRuntimeMessage(message, sender: sender,
                                                                  to: extensionID, senderToken: token) else {
                return NSNull()
            }
            return response

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
        let sender: [String: Any] = ["id": extensionID]
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

    // MARK: - getContentScripts

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
                                                 webView: webView, frameInfo: frameInfo))
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
            // session exactly as manifest content scripts do (world is stored but iOS runs one world).
            for userScript in await BrownBearServices.shared.webExtensionUserScriptStore
                .getScripts(extensionID: ext.id, ids: nil) {
                if isSubframe && !userScript.allFrames { continue }
                let matcher = URLMatcher(matches: userScript.matches, includes: userScript.includeGlobs,
                                         excludes: userScript.excludeGlobs, excludeMatches: userScript.excludeMatches)
                guard matcher.matches(urlString) else { continue }
                let token = UUID().uuidString
                registerSession(token: token,
                                session: Session(extensionID: ext.id, isContent: true,
                                                 webView: webView, frameInfo: frameInfo))
                result.append([
                    "token": token,
                    "extensionId": ext.id,
                    "runAt": userScript.runAt,
                    "allFrames": userScript.allFrames,
                    "js": userScript.js,
                    "css": "",
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


// MARK: - chrome.cookies / notifications / action / windows / management / permissions
//
// Split into a same-file extension so the primary type body stays under the length limit; a
// same-file extension still reaches the class's `private` members (store/host/cookieHost/…).
extension WebExtensionMessageRouter {

    // chrome.cookies routing + the scripting/cookies permission gates live in
    // WebExtensionMessageRouter+Permissions.swift (file-length limit).

    // MARK: - chrome.notifications

    /// chrome.notifications — UNUserNotificationCenter-backed via the bridge host. `extensionID`
    /// (resolved from the token above) gates the manifest "notifications" permission in the manager.
    private func routeNotifications(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        switch api {
        case "notifications.create":
            guard let host else { throw BrownBearError.bridgeRejected("no browser for notifications") }
            return try await host.webExtNotificationsCreate(
                extensionID: extensionID,
                notificationID: payload["notificationId"] as? String,
                options: payload["options"] as? [String: Any] ?? [:])

        case "notifications.update":
            guard let host, let id = payload["notificationId"] as? String else { return false }
            return try await host.webExtNotificationsUpdate(
                extensionID: extensionID, notificationID: id,
                options: payload["options"] as? [String: Any] ?? [:])

        case "notifications.clear":
            guard let host, let id = payload["notificationId"] as? String else { return false }
            return try await host.webExtNotificationsClear(extensionID: extensionID, notificationID: id)

        case "notifications.getAll":
            guard let host else { return [String: Bool]() }
            return try await host.webExtNotificationsGetAll(extensionID: extensionID)

        default:
            throw BrownBearError.bridgeRejected("unsupported notifications api '\(api)'")
        }
    }

    // MARK: - chrome.action / chrome.browserAction

    /// chrome.action setters/getters. State lives in the shared WebExtensionActionState (no permission
    /// needed — Chrome gates it on the manifest action entry; the token was already resolved). A
    /// tab-less property defaults to the active tab, resolved via the host. All synchronous.
    private func routeAction(api: String, payload: [String: Any], extensionID: String) -> Any? {
        let state = BrownBearServices.shared.webExtensionActionState
        let tabId = (payload["tabId"] as? Int) ?? host?.webExtActionActiveTabId()
        switch api {
        case "action.setBadgeText":
            state.setBadgeText(extensionID: extensionID, tabId: tabId, text: payload["text"] as? String)
            return NSNull()
        case "action.setBadgeBackgroundColor":
            state.setBadgeColor(extensionID: extensionID, tabId: tabId, color: payload["color"] as? String)
            return NSNull()
        case "action.setTitle":
            state.setTitle(extensionID: extensionID, tabId: tabId, title: payload["title"] as? String)
            return NSNull()
        case "action.setPopup":
            state.setPopup(extensionID: extensionID, tabId: tabId, popup: payload["popup"] as? String)
            return NSNull()
        case "action.setIcon":
            state.setIcon(extensionID: extensionID, tabId: tabId, path: WebExtensionActionState.iconPath(from: payload["path"]))
            return NSNull()
        case "action.enable":
            state.setEnabled(extensionID: extensionID, tabId: tabId, true)
            return NSNull()
        case "action.disable":
            state.setEnabled(extensionID: extensionID, tabId: tabId, false)
            return NSNull()
        case "action.getBadgeText":
            return state.badgeText(extensionID: extensionID, tabId: tabId)
        case "action.getTitle":
            return state.title(extensionID: extensionID, tabId: tabId)
        case "action.getBadgeBackgroundColor":
            return state.badgeColorBytes(extensionID: extensionID, tabId: tabId)
        default:
            return NSNull()
        }
    }

    // MARK: - chrome.windows / chrome.management / chrome.permissions

    /// chrome.windows (single synthetic window on iOS), chrome.management (read-only), and
    /// chrome.permissions (optional-grant store) + runtime.setUninstallURL/getPlatformInfo. Split out
    /// to keep route() under the complexity limit. A valid extension token is already resolved.
    private func routeWindowsManagementPermissions(api: String, payload: [String: Any],
                                                   extensionID: String) async throws -> Any? {
        switch api {
        case "windows.get", "windows.getCurrent", "windows.getLastFocused":
            guard let host else { return NSNull() }
            return host.webExtWindow(populate: (payload["populate"] as? Bool) ?? false)

        case "windows.getAll":
            guard let host else { return [] }
            return host.webExtAllWindows(populate: (payload["populate"] as? Bool) ?? false)

        case "windows.create":
            guard let host else { throw BrownBearError.bridgeRejected("no browser to open a window") }
            return host.webExtCreateWindow(url: payload["url"] as? String,
                                           active: (payload["focused"] as? Bool) ?? true,
                                           populate: (payload["populate"] as? Bool) ?? false)

        case "windows.update":
            guard let host else { return NSNull() }
            return host.webExtUpdateWindow(populate: (payload["populate"] as? Bool) ?? false)

        case "windows.remove":
            return NSNull()   // iOS has one window that can't be closed; acknowledge so JS settles.

        case "management.getAll":
            return WebExtensionManagementInfo.allExtensionInfos(await store.all())

        case "management.get":
            guard let id = payload["id"] as? String, let ext = await store.ext(for: id) else {
                throw BrownBearError.bridgeRejected("no extension with id '\(payload["id"] as? String ?? "")'")
            }
            return WebExtensionManagementInfo.extensionInfo(for: ext)

        case "management.getSelf":
            guard let ext = await store.ext(for: extensionID) else { return NSNull() }
            return WebExtensionManagementInfo.extensionInfo(for: ext)

        case "permissions.getAll":
            let manifest = await store.ext(for: extensionID)?.manifest
            let granted = await BrownBearServices.shared.webExtensionPermissionGrants.granted(extensionID: extensionID)
            return WebExtensionManagementInfo.effective(manifest: manifest, granted: granted).dictionary

        case "permissions.contains":
            let manifest = await store.ext(for: extensionID)?.manifest
            let granted = await BrownBearServices.shared.webExtensionPermissionGrants.granted(extensionID: extensionID)
            let requested = WebExtensionManagementInfo.PermissionSet(payload: payload)
            return WebExtensionManagementInfo.contains(requested, manifest: manifest, granted: granted)

        case "permissions.request":
            let ext = await store.ext(for: extensionID)
            let manifest = ext?.manifest
            let grants = BrownBearServices.shared.webExtensionPermissionGrants
            let requested = WebExtensionManagementInfo.PermissionSet(payload: payload)
            // Reject anything the manifest never declared (required or optional) — Chrome parity.
            guard let toGrant = WebExtensionManagementInfo.resolveRequest(requested, manifest: manifest) else { return false }
            // Only prompt for what is NOT already held; an already-held request resolves true silently.
            let held = await grants.granted(extensionID: extensionID)
            let effective = WebExtensionManagementInfo.effective(manifest: manifest, granted: held)
            var newlyRequested = toGrant
            newlyRequested.permissions.subtract(effective.permissions)
            newlyRequested.origins.subtract(effective.origins)
            // User consent gate (replaces the old auto-grant). Deny ⇒ resolve false, grant nothing.
            guard await WebExtensionPermissionPrompt.request(extensionName: ext?.displayName ?? extensionID,
                                                             toGrant: newlyRequested) else { return false }
            await grants.grant(extensionID: extensionID, newlyRequested)
            return true

        case "permissions.remove":
            let manifest = await store.ext(for: extensionID)?.manifest
            let grants = BrownBearServices.shared.webExtensionPermissionGrants
            let granted = await grants.granted(extensionID: extensionID)
            let requested = WebExtensionManagementInfo.PermissionSet(payload: payload)
            guard let remaining = WebExtensionManagementInfo.resolveRemove(requested, manifest: manifest, granted: granted) else {
                return false
            }
            await grants.setGranted(extensionID: extensionID, remaining)
            return true

        case "runtime.setUninstallURL":
            let url = (payload["url"] as? String) ?? ""
            await BrownBearServices.shared.webExtensionPermissionGrants.setUninstallURL(extensionID: extensionID, url: url)
            return NSNull()

        case "runtime.getPlatformInfo":
            return ["os": "ios", "arch": "arm64", "nacl_arch": "arm64"]

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    // MARK: - chrome.declarativeNetRequest (dynamic/session) + chrome.userScripts (MV3)

    /// declarativeNetRequest runtime rules + chrome.userScripts registration. Both are permission-gated
    /// (declarativeNetRequest[WithHostAccess] / userScripts). A mutation posts the change notification so
    /// the content blocker recompiles and userScripts inject on the next navigation.
    private func routeDNRUserScripts(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        switch api {
        case "dnr.updateDynamicRules", "dnr.updateSessionRules", "dnr.updateEnabledRulesets":
            try await requireDNRPermission(extensionID)
            let dnrStore = BrownBearServices.shared.webExtensionDNRStore
            if api == "dnr.updateDynamicRules" {
                try await dnrStore.updateDynamicRules(extensionID: extensionID, update: Self.parseRuleUpdate(payload))
            } else if api == "dnr.updateSessionRules" {
                try await dnrStore.updateSessionRules(extensionID: extensionID, update: Self.parseRuleUpdate(payload))
            } else {
                let rulesets = await store.ext(for: extensionID)?.manifest?.declarativeNetRequest ?? []
                try await dnrStore.updateEnabledRulesets(
                    extensionID: extensionID,
                    manifestDefaults: rulesets.filter(\.enabled).map(\.id),
                    allRulesetIDs: rulesets.map(\.id),
                    disable: (payload["disableRulesetIds"] as? [String]) ?? [],
                    enable: (payload["enableRulesetIds"] as? [String]) ?? [])
            }
            NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
            return NSNull()

        case "dnr.getDynamicRules":
            try await requireDNRPermission(extensionID)
            let rules = await BrownBearServices.shared.webExtensionDNRStore.getDynamicRules(extensionID: extensionID)
            return Self.filterRules(rules, ids: payload["ruleIds"] as? [Int])

        case "dnr.getSessionRules":
            try await requireDNRPermission(extensionID)
            let rules = await BrownBearServices.shared.webExtensionDNRStore.getSessionRules(extensionID: extensionID)
            return Self.filterRules(rules, ids: payload["ruleIds"] as? [Int])

        case "dnr.getEnabledRulesets":
            try await requireDNRPermission(extensionID)
            let rulesets = await store.ext(for: extensionID)?.manifest?.declarativeNetRequest ?? []
            let enabled = await BrownBearServices.shared.webExtensionDNRStore
                .enabledRulesetIDs(extensionID: extensionID, manifestDefaults: rulesets.filter(\.enabled).map(\.id))
            return rulesets.map(\.id).filter { enabled.contains($0) }

        case "userScripts.register", "userScripts.update":
            try await requireUserScriptsPermission(extensionID)
            let resolved = try await resolveRegisteredScripts(extensionID: extensionID,
                                                              raw: payload["scripts"] as? [[String: Any]] ?? [])
            let userScriptStore = BrownBearServices.shared.webExtensionUserScriptStore
            if api == "userScripts.register" {
                try await userScriptStore.register(extensionID: extensionID, scripts: resolved)
            } else {
                try await userScriptStore.update(extensionID: extensionID, scripts: resolved)
            }
            return NSNull()

        case "userScripts.getScripts":
            try await requireUserScriptsPermission(extensionID)
            let filter = (payload["filter"] as? [String: Any])?["ids"] as? [String]
            let scripts = await BrownBearServices.shared.webExtensionUserScriptStore
                .getScripts(extensionID: extensionID, ids: filter)
            return scripts.map(Self.userScriptDict)

        case "userScripts.unregister":
            try await requireUserScriptsPermission(extensionID)
            let ids = (payload["filter"] as? [String: Any])?["ids"] as? [String]
            await BrownBearServices.shared.webExtensionUserScriptStore.unregister(extensionID: extensionID, ids: ids)
            return NSNull()

        case "userScripts.configureWorld":
            try await requireUserScriptsPermission(extensionID)
            let properties = payload["properties"] as? [String: Any] ?? [:]
            let config = WebExtensionUserScriptStore.WorldConfig(
                worldId: properties["worldId"] as? String,
                csp: properties["csp"] as? String,
                messaging: (properties["messaging"] as? Bool) ?? false)
            await BrownBearServices.shared.webExtensionUserScriptStore.configureWorld(extensionID: extensionID, config: config)
            return NSNull()

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    /// declarativeNetRequest is privileged: require the API permission before any read OR write.
    private func requireDNRPermission(_ extensionID: String) async throws {
        let perms = await store.ext(for: extensionID)?.manifest?.permissions ?? []
        guard perms.contains("declarativeNetRequest") || perms.contains("declarativeNetRequestWithHostAccess") else {
            throw BrownBearError.bridgeRejected("declarativeNetRequest permission not granted")
        }
    }

    private func requireUserScriptsPermission(_ extensionID: String) async throws {
        let perms = await store.ext(for: extensionID)?.manifest?.permissions ?? []
        guard perms.contains("userScripts") else {
            throw BrownBearError.bridgeRejected("userScripts permission not granted")
        }
    }


    /// Build a RuleUpdate from a chrome update payload (addRules + removeRuleIds).
    static func parseRuleUpdate(_ payload: [String: Any]) -> WebExtensionDNRStore.RuleUpdate {
        WebExtensionDNRStore.RuleUpdate(
            removeRuleIDs: (payload["removeRuleIds"] as? [Int]) ?? [],
            addRules: (payload["addRules"] as? [[String: Any]]) ?? [])
    }

    /// chrome's get*Rules takes an optional ruleIds filter.
    static func filterRules(_ rules: [[String: Any]], ids: [Int]?) -> [[String: Any]] {
        guard let ids else { return rules }
        let wanted = Set(ids)
        return rules.filter { ($0["id"] as? Int).map(wanted.contains) ?? false }
    }

    static func userScriptDict(_ script: WebExtensionUserScriptStore.RegisteredScript) -> [String: Any] {
        [
            "id": script.id,
            "matches": script.matches,
            "excludeMatches": script.excludeMatches,
            "includeGlobs": script.includeGlobs,
            "excludeGlobs": script.excludeGlobs,
            "js": [["code": script.js]],   // chrome returns ScriptSource[]; we round-trip resolved code
            "runAt": script.runAt,
            "allFrames": script.allFrames,
            "world": script.world
        ]
    }

    /// Resolve register/update ScriptSource[] (each { code } OR { file }) to a flat source string and
    /// normalize match/run-at fields. A `file` is read from the extension's package (containment-safe).
    /// Fails closed if a script has neither code nor a readable file, or no matches.
    private func resolveRegisteredScripts(extensionID: String,
                                          raw: [[String: Any]]) async throws -> [WebExtensionUserScriptStore.RegisteredScript] {
        var out: [WebExtensionUserScriptStore.RegisteredScript] = []
        for entry in raw {
            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: every script needs an id")
            }
            let matches = (entry["matches"] as? [String]) ?? []
            guard !matches.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: script '\(id)' has no matches")
            }
            var source = ""
            for js in (entry["js"] as? [[String: Any]]) ?? [] {
                if let code = js["code"] as? String {
                    source += code + "\n;\n"
                } else if let file = js["file"] as? String,
                          let text = await store.text(extensionID: extensionID, path: file) {
                    source += text + "\n;\n"
                }
            }
            guard !source.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: script '\(id)' has no usable js")
            }
            out.append(WebExtensionUserScriptStore.RegisteredScript(
                id: id,
                matches: matches,
                excludeMatches: (entry["excludeMatches"] as? [String]) ?? [],
                includeGlobs: (entry["includeGlobs"] as? [String]) ?? [],
                excludeGlobs: (entry["excludeGlobs"] as? [String]) ?? [],
                js: source,
                runAt: (entry["runAt"] as? String) ?? "document_idle",
                allFrames: (entry["allFrames"] as? Bool) ?? false,
                world: (entry["world"] as? String) ?? "USER_SCRIPT"))
        }
        return out
    }
}
