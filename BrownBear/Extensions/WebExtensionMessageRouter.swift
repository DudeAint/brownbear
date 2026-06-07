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

    private let store: WebExtensionStore
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
            // Content script / popup → its own extension's background worker. `message` is any JSON.
            let message = payload["message"] ?? NSNull()
            var sender: [String: Any] = ["id": extensionID]
            if let url = payload["url"] as? String { sender["url"] = url }
            guard let response = await runtime.sendRuntimeMessage(message, sender: sender, to: extensionID) else {
                return NSNull()
            }
            return response

        case "runtime.openOptionsPage":
            // The options page is opened from BrownBear's own UI (dashboard/browser); acknowledge so
            // the page's callback fires without error. (Programmatic navigation isn't wired here.)
            return NSNull()

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

        default:
            guard let result = await routeTabsAndScripting(api: api, payload: payload, extensionID: extensionID) else {
                throw BrownBearError.bridgeRejected("unsupported extension api '\(api)'")
            }
            return result
        }
    }

    // MARK: - chrome.cookies

    private func routeCookies(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        guard let host = cookieHost else { return NSNull() }
        let details = (payload["details"] as? [String: Any]) ?? [:]
        let storeId = details["storeId"] as? String
        guard try await hasCookiesPermission(extensionID: extensionID) else {
            throw BrownBearError.bridgeRejected("the \"cookies\" permission is not granted")
        }
        switch api {
        case "cookies.get":
            guard let url = details["url"] as? String, let name = details["name"] as? String else {
                throw BrownBearError.bridgeRejected("cookies.get requires url and name")
            }
            guard try await cookieHostAllowed(extensionID: extensionID, details: details) else {
                throw BrownBearError.bridgeRejected("no host permission for \(url)")
            }
            return await host.webExtGetCookie(url: url, name: name, storeId: storeId) ?? NSNull()
        case "cookies.getAll":
            guard try await cookieHostAllowed(extensionID: extensionID, details: details) else {
                throw BrownBearError.bridgeRejected("no host permission for this cookies.getAll filter")
            }
            return await host.webExtGetAllCookies(filter: details, storeId: storeId)
        case "cookies.set":
            guard try await cookieHostAllowed(extensionID: extensionID, details: details) else {
                throw BrownBearError.bridgeRejected("no host permission for cookies.set")
            }
            return await host.webExtSetCookie(details: details, storeId: storeId) ?? NSNull()
        case "cookies.remove":
            guard let url = details["url"] as? String, let name = details["name"] as? String else {
                throw BrownBearError.bridgeRejected("cookies.remove requires url and name")
            }
            guard try await cookieHostAllowed(extensionID: extensionID, details: details) else {
                throw BrownBearError.bridgeRejected("no host permission for \(url)")
            }
            return await host.webExtRemoveCookie(url: url, name: name, storeId: storeId) ?? NSNull()
        case "cookies.getAllCookieStores":
            return host.webExtGetAllCookieStores()
        default:
            throw BrownBearError.bridgeRejected("unsupported cookies api '\(api)'")
        }
    }

    private func hasCookiesPermission(extensionID: String) async throws -> Bool {
        guard let manifest = await store.ext(for: extensionID)?.manifest else { return false }
        return manifest.permissions.contains("cookies")
    }

    private func cookieHostAllowed(extensionID: String, details: [String: Any]) async throws -> Bool {
        guard let manifest = await store.ext(for: extensionID)?.manifest else { return false }
        let targetURL: String?
        if let url = details["url"] as? String { targetURL = url }
        else if let domain = details["domain"] as? String, !domain.isEmpty {
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            targetURL = "https://\(host)/"
        } else { targetURL = nil }
        guard let targetURL else { return true }
        let matcher = URLMatcher(matches: manifest.effectiveHostPatterns,
                                 includes: [], excludes: [], excludeMatches: [])
        return matcher.matches(targetURL)
    }

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
            let code = await resolveInjectedCode(payload: payload, extensionID: extensionID, separator: "\n;\n")
            guard !code.isEmpty else { return [] }
            return await host.webExtExecuteScript(extTabId: target["tabId"] as? Int,
                                                  world: (payload["world"] as? String) ?? "ISOLATED", code: code)

        case "scripting.insertCSS", "scripting.removeCSS":
            guard let host else { return NSNull() }
            let target = payload["target"] as? [String: Any] ?? [:]
            let css = await resolveInjectedCSS(payload: payload, extensionID: extensionID)
            if api == "scripting.insertCSS" {
                host.webExtInsertCSS(extTabId: target["tabId"] as? Int, css: css)
            } else {
                host.webExtRemoveCSS(extTabId: target["tabId"] as? Int, css: css)
            }
            return NSNull()

        case "tabs.executeScript":
            guard let host else { return [] }
            var code = payload["code"] as? String ?? ""
            if code.isEmpty, let file = payload["file"] as? String,
               let text = await store.text(extensionID: extensionID, path: file) { code = text }
            guard !code.isEmpty else { return [] }
            let results = await host.webExtExecuteScript(extTabId: payload["tabId"] as? Int,
                                                         world: (payload["world"] as? String) ?? "ISOLATED", code: code)
            return results.map { $0["result"] ?? NSNull() }   // MV2 returns the raw results array

        case "tabs.insertCSS":
            guard let host else { return NSNull() }
            var css = payload["code"] as? String ?? ""
            if css.isEmpty, let file = payload["file"] as? String,
               let text = await store.text(extensionID: extensionID, path: file) { css = text }
            host.webExtInsertCSS(extTabId: payload["tabId"] as? Int, css: css)
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
    /// string/number/bool message round-trips. Falls back to `null` if it isn't JSON-serializable.
    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }

    // MARK: - Identity / sessions

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
