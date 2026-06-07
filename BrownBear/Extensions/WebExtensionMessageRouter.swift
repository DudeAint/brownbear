//
//  WebExtensionMessageRouter.swift
//  BrownBear
//
//  The native side of the extension runtime. It answers getContentScripts (which extensions'
//  content scripts match this URL, with their JS/CSS/manifest/i18n) and the chrome.storage.*
//  calls, with the same native-bound-token identity model as the userscript bridge so one
//  extension's storage stays isolated from another's.
//

import WebKit

@MainActor
final class WebExtensionMessageRouter: NSObject, WKScriptMessageHandlerWithReply {

    static let handlerName = "brownbearWebext"

    private let store: WebExtensionStore
    private let storage: WebExtensionStorage
    private let runtime: WebExtensionRuntime
    /// Lets chrome.tabs reach the browser's TabManager. Set via InjectionOrchestrator.
    weak var host: WebExtensionBridgeHost?
    /// token → extension id. Minted per content-script injection / page.
    private var sessions: [String: String] = [:]
    /// Insertion order of tokens, for FIFO eviction once `sessions` exceeds `maxSessions`.
    private var tokenOrder: [String] = []

    init(store: WebExtensionStore, storage: WebExtensionStorage, runtime: WebExtensionRuntime) {
        self.store = store
        self.storage = storage
        self.runtime = runtime
    }

    /// Mint a token bound to `extensionID` for an extension PAGE (popup/options). The page's chrome.*
    /// surface carries this token so its storage/runtime calls resolve to the right extension — the
    /// same native-bound identity model content scripts use.
    func makePageSession(for extensionID: String) -> String {
        let token = UUID().uuidString
        registerSession(token: token, extensionID: extensionID)
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

        Task { @MainActor in
            do {
                let result = try await self.route(api: api, payload: payload, token: token)
                replyHandler(result, nil)
            } catch let error as BrownBearError {
                replyHandler(nil, error.errorDescription ?? "extension bridge error")
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Routing

    private func route(api: String, payload: [String: Any], token: String?) async throws -> Any? {
        if api == "getContentScripts" {
            return try await handleGetContentScripts(payload: payload)
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

        default:
            guard let result = await routeTabsAndScripting(api: api, payload: payload, extensionID: extensionID) else {
                throw BrownBearError.bridgeRejected("unsupported extension api '\(api)'")
            }
            return result
        }
    }

    /// chrome.tabs + chrome.scripting routing — driven through the browser's TabManager via the bridge
    /// host. Split out so route() stays under the complexity limit. Returns nil for an api it doesn't
    /// handle (route() then rejects it). A valid extension token is already resolved by route().
    private func routeTabsAndScripting(api: String, payload: [String: Any], extensionID: String) async -> Any? {
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

        // chrome.scripting (MV3) + chrome.tabs.executeScript/insertCSS (MV2). `func`/`args` are
        // serialized to `code` by the JS shim; `files` are read from the extension's own package here.
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
            if api == "scripting.insertCSS" { host.webExtInsertCSS(extTabId: target["tabId"] as? Int, css: css) }
            else { host.webExtRemoveCSS(extTabId: target["tabId"] as? Int, css: css) }
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

    /// The JS to inject for chrome.scripting/tabs.executeScript: an explicit `code` string (the shim
    /// serializes `func`+`args` into one), else the named `files` read from the extension's package.
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

    private func resolve(_ token: String?) async throws -> String {
        guard let token, let extensionID = sessions[token] else {
            throw BrownBearError.bridgeRejected("unrecognized extension token")
        }
        // Fail closed if the extension was disabled/removed after this token was minted — otherwise
        // an already-injected content script keeps read/write access to storage until it navigates.
        guard await store.ext(for: extensionID)?.enabled == true else {
            sessions.removeValue(forKey: token)
            throw BrownBearError.bridgeRejected("extension is disabled")
        }
        return extensionID
    }

    /// token → extensionID, with a FIFO cap so the map can't grow unbounded across a long session of
    /// navigations (a fresh token is minted per content-script injection / page).
    private static let maxSessions = 2000
    private func registerSession(token: String, extensionID: String) {
        sessions[token] = extensionID
        tokenOrder.append(token)
        if tokenOrder.count > Self.maxSessions {
            let evicted = tokenOrder.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
    }

    // MARK: - getContentScripts

    private func handleGetContentScripts(payload: [String: Any]) async throws -> [[String: Any]] {
        guard let urlString = payload["url"] as? String else {
            throw BrownBearError.bridgeRejected("missing url")
        }
        let isSubframe = (payload["isSubframe"] as? Bool) ?? false
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
                registerSession(token: token, extensionID: ext.id)
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
