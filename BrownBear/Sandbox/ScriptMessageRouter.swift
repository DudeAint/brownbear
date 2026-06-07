//
//  ScriptMessageRouter.swift
//  BrownBear
//
//  The single trust boundary between injected JavaScript and native Swift. Every GM_* call the
//  sandbox makes arrives here as one `brownbear` message; we validate it, perform the privileged
//  work (storage, network, clipboard, tabs), and reply. Uses WKScriptMessageHandlerWithReply
//  (iOS 14+) so the JS `postMessage` returns a Promise.
//
//  Security (CLAUDE.md §5), hardened after adversarial review:
//   • Script identity is NATIVE-BOUND. getScripts mints a random per-injection token, maps it to
//     the script's UUID + grants + @connect, and hands only the token to that script's closure.
//     JS never supplies its own scriptId, so value namespaces and grants are un-spoofable.
//   • Grants are re-enforced here for every gated API — JS gating is defense-in-depth only.
//   • GM_xmlhttpRequest fails closed: no resolved script ⇒ no request; @connect is enforced.
//

import UIKit
import WebKit

/// Lets the bridge ask the browser to perform UI actions it can't do itself (open tabs).
@MainActor
protocol ScriptBridgeHost: AnyObject {
    func bridgeOpenInTab(url: URL, active: Bool)
}

@MainActor
final class ScriptMessageRouter: NSObject, WKScriptMessageHandlerWithReply {

    /// The message handler name JS posts to: `window.webkit.messageHandlers.brownbear`.
    static let handlerName = "brownbear"

    /// The native-bound identity behind a token. Created in getScripts, looked up on every call.
    private struct ScriptSession {
        let id: UUID
        /// The script's display name, for attributing log lines.
        let name: String
        let grants: Set<String>
        let connects: [String]
        /// URLs the script declared via @require / @resource — the only URLs fetchResource serves.
        var assetURLs: Set<String> = []
        /// The web view + frame this injection lives in, so native can push GM value changes made by
        /// the SAME script in another frame/tab into this one's content world (weak: don't pin a tab).
        weak var webView: WKWebView?
        var frameInfo: WKFrameInfo?
    }

    private let scriptStore: ScriptStore
    private let valueStore: GMValueStore
    private let network: GMNetworkService
    private let logStore: LogStore
    private let contentWorld: WKContentWorld
    /// Per-script user grants for hosts not in `@connect` (ScriptCat-style allow-always).
    private let grantStore: ConnectGrantStore
    weak var host: ScriptBridgeHost?

    /// In-flight @connect prompts keyed by "scriptID|host", so a script firing many requests to the
    /// same undeclared host shows ONE alert and the rest await its decision instead of stacking.
    private var pendingGrantDecisions: [String: Task<Bool, Never>] = [:]

    /// Cap a single forwarded log line so a runaway script can't bloat the on-disk log.
    private static let maxLogMessageLength = 8192

    /// token → session. Tokens are random per injection; a script only ever sees its own.
    private var sessions: [String: ScriptSession] = [:]
    /// Insertion order, for FIFO eviction so the shared router's map can't grow unbounded across
    /// every tab, navigation, and frame for the life of the app.
    private var tokenOrder: [String] = []
    private static let maxSessions = 2000

    /// Which @grant names satisfy each gated API (classic and GM.* aliases).
    private static let grantAliases: [String: Set<String>] = [
        "GM_getValue": ["GM_getValue", "GM.getValue"],
        "GM_setValue": ["GM_setValue", "GM.setValue"],
        "GM_deleteValue": ["GM_deleteValue", "GM.deleteValue"],
        "GM_listValues": ["GM_listValues", "GM.listValues"],
        "GM_getValues": ["GM_getValues", "GM.getValues"],
        "GM_setValues": ["GM_setValues", "GM.setValues"],
        "GM_deleteValues": ["GM_deleteValues", "GM.deleteValues"],
        "GM_setClipboard": ["GM_setClipboard", "GM.setClipboard"],
        "GM_openInTab": ["GM_openInTab", "GM.openInTab"],
        "GM_log": ["GM_log", "GM.log"],
        "GM_xmlhttpRequest": ["GM_xmlhttpRequest", "GM.xmlHttpRequest"]
    ]

    init(scriptStore: ScriptStore,
         valueStore: GMValueStore,
         network: GMNetworkService,
         logStore: LogStore,
         contentWorld: WKContentWorld,
         grantStore: ConnectGrantStore = BrownBearServices.shared.connectGrantStore) {
        self.scriptStore = scriptStore
        self.valueStore = valueStore
        self.network = network
        self.logStore = logStore
        self.contentWorld = contentWorld
        self.grantStore = grantStore
    }

    // MARK: - WKScriptMessageHandlerWithReply

    // `nonisolated` to satisfy the non-isolated protocol requirement cleanly; we read the
    // message on WebKit's delivery thread (main) and hop to the MainActor for the actual work,
    // avoiding any actor-executor assumption mismatch.
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let api = body["api"] as? String else {
            replyHandler(nil, "malformed bridge message")
            return
        }
        let payload = body["payload"] as? [String: Any] ?? [:]
        let token = body["token"] as? String
        let frameInfo = message.frameInfo
        let frameURL = frameInfo.request.url
        let webView = message.webView

        Task { @MainActor in
            do {
                let result = try await self.route(api: api,
                                                  payload: payload,
                                                  token: token,
                                                  frameURL: frameURL,
                                                  frameInfo: frameInfo,
                                                  webView: webView)
                replyHandler(result, nil)
            } catch let error as BrownBearError {
                replyHandler(nil, error.errorDescription ?? "bridge error")
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Routing

    private func route(api: String,
                       payload: [String: Any],
                       token: String?,
                       frameURL: URL?,
                       frameInfo: WKFrameInfo?,
                       webView: WKWebView?) async throws -> Any? {
        // getScripts is the loader's privilege; it needs no token and mints them.
        if api == "getScripts" {
            return try await handleGetScripts(payload: payload, webView: webView, frameInfo: frameInfo)
        }
        // GM_abortRequest only cancels the caller's own request by id — safe without a grant.
        if api == "GM_abortRequest" {
            if let requestID = payload["requestId"] as? String { network.abort(requestID: requestID) }
            return NSNull()
        }

        // Everything else requires a native-bound session and a grant.
        let session = try resolveSession(token)
        try ensureGranted(api: api, session: session)

        switch api {
        case "GM_getValue":
            guard let key = payload["key"] as? String else { throw BrownBearError.bridgeRejected("missing key") }
            return await valueStore.value(scriptID: session.id, key: key) ?? NSNull()

        case "GM_setValue":
            guard let key = payload["key"] as? String, let json = payload["value"] as? String else {
                throw BrownBearError.bridgeRejected("missing key/value")
            }
            let old = await valueStore.setValueReturningOld(scriptID: session.id, key: key, jsonValue: json)
            broadcastValueChanges(scriptID: session.id, originToken: token, changes: [(key, old, json)])
            return NSNull()

        case "GM_deleteValue":
            guard let key = payload["key"] as? String else { throw BrownBearError.bridgeRejected("missing key") }
            let old = await valueStore.deleteValueReturningOld(scriptID: session.id, key: key)
            broadcastValueChanges(scriptID: session.id, originToken: token, changes: [(key, old, nil)])
            return NSNull()

        case "GM_listValues":
            return await valueStore.listValues(scriptID: session.id)

        case "GM_setValues":
            guard let entries = payload["values"] as? [String: String] else {
                throw BrownBearError.bridgeRejected("missing values")
            }
            let olds = await valueStore.setValuesReturningOld(scriptID: session.id, entries: entries)
            let changes = olds.map { (key: $0.key, old: $0.old, new: entries[$0.key]) }
            broadcastValueChanges(scriptID: session.id, originToken: token, changes: changes)
            return NSNull()

        case "GM_deleteValues":
            guard let keys = payload["keys"] as? [String] else { throw BrownBearError.bridgeRejected("missing keys") }
            let olds = await valueStore.deleteValuesReturningOld(scriptID: session.id, keys: keys)
            let changes = olds.map { (key: $0.key, old: $0.old, new: String?.none) }
            broadcastValueChanges(scriptID: session.id, originToken: token, changes: changes)
            return NSNull()

        case "GM_setClipboard":
            guard let data = payload["data"] as? String else { throw BrownBearError.bridgeRejected("missing data") }
            UIPasteboard.general.string = data
            return NSNull()

        case "GM_openInTab":
            guard let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
                throw BrownBearError.bridgeRejected("invalid url")
            }
            host?.bridgeOpenInTab(url: url, active: (payload["active"] as? Bool) ?? true)
            return NSNull()

        case "GM_log", "log":
            // Both GM_log and the runtime's bridged console.* land here. GM_log is grant-gated
            // (above); "log" (console forwarding) is ungated so it works for every script,
            // including @grant none. Writes a foreground LogEntry the dashboard's Logs tab shows.
            let levelRaw = (payload["level"] as? String) ?? "info"
            let level = LogEntry.Level(rawValue: levelRaw) ?? .info
            let raw = (payload["message"] as? String) ?? ""
            let message = raw.count > Self.maxLogMessageLength
                ? String(raw.prefix(Self.maxLogMessageLength)) + "…"
                : raw
            await logStore.append(LogEntry(scriptID: session.id,
                                           scriptName: session.name,
                                           level: level,
                                           message: message,
                                           context: .foreground))
            return NSNull()

        case "GM_xmlhttpRequest":
            try await handleXHR(payload: payload, session: session, frameURL: frameURL, webView: webView)
            return NSNull()

        case "fetchResource":
            // Fetch a declared @require/@resource natively (no page CORS), so lib-dependent and
            // obfuscated scripts load their dependencies reliably. Restricted to the script's own
            // declared asset URLs so it can't be used as an open fetch proxy.
            guard let urlString = payload["url"] as? String else {
                throw BrownBearError.bridgeRejected("missing url")
            }
            guard session.assetURLs.contains(urlString), let url = URL(string: urlString) else {
                throw BrownBearError.bridgeRejected("url is not a declared @require/@resource")
            }
            return try await fetchAsset(url)

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    /// Fetch a script asset (@require/@resource) natively. Returns text + base64 + mime so the
    /// runtime can serve both GM_getResourceText and GM_getResourceURL (as a data: URL).
    private func fetchAsset(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            ?? "application/octet-stream"
        return [
            "text": String(data: data, encoding: .utf8) ?? "",
            "base64": data.base64EncodedString(),
            "mimeType": mime
        ]
    }

    // MARK: - Identity & grants

    private func resolveSession(_ token: String?) throws -> ScriptSession {
        guard let token, let session = sessions[token] else {
            throw BrownBearError.bridgeRejected("unrecognized or missing script token")
        }
        return session
    }

    /// Insert a session, evicting once the map exceeds `maxSessions`. Prefer dropping a DEAD session
    /// (its web view deallocated) over a live one, so the cap can't sever an in-use script's
    /// identity/grants mid-run.
    private func registerSession(token: String, session: ScriptSession) {
        sessions[token] = session
        tokenOrder.append(token)
        guard tokenOrder.count > Self.maxSessions else { return }
        if let deadIndex = tokenOrder.firstIndex(where: { sessions[$0]?.webView == nil }) {
            let evicted = tokenOrder.remove(at: deadIndex)
            sessions.removeValue(forKey: evicted)
        } else {
            let evicted = tokenOrder.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
    }

    /// Drop every session for a web view — called when its main frame (re)loads, so stale tokens
    /// from the prior page (and their now-defunct frames) don't linger or receive value broadcasts.
    private func purgeSessions(for webView: WKWebView) {
        let stale = Set(sessions.compactMap { $0.value.webView === webView ? $0.key : nil })
        guard !stale.isEmpty else { return }
        for token in stale { sessions.removeValue(forKey: token) }
        tokenOrder.removeAll { stale.contains($0) }
    }

    // MARK: - GM value propagation (cross-frame + cross-tab, ScriptCat parity)

    /// Push value changes into every OTHER live injection of the same script — its instances in
    /// other frames (iframes) and other tabs — so GM_getValue and GM_addValueChangeListener stay in
    /// sync in real time, with `remote = true` on the far side. `old`/`new` are JSON-encoded value
    /// strings; `new == nil` means the key was deleted.
    private func broadcastValueChanges(scriptID: UUID,
                                       originToken: String?,
                                       changes: [(key: String, old: String?, new: String?)]) {
        guard !changes.isEmpty else { return }
        for (token, target) in sessions where target.id == scriptID && token != originToken {
            guard let webView = target.webView else { continue }
            for change in changes {
                var payload: [String: Any] = ["token": token, "key": change.key]
                payload["old"] = change.old ?? NSNull()
                payload["new"] = change.new ?? NSNull()
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: data, encoding: .utf8) else { continue }
                let js = "window.__brownbear&&window.__brownbear.applyValueChange('\(Self.escapeForJSStringLiteral(json))');"
                // Via the ObjC shim, into the EXACT frame this injection runs in (iframe-aware).
                BBEvaluateJavaScriptInFrame(webView, js, target.frameInfo, contentWorld)
            }
        }
    }

    /// Escape a string for embedding inside a single-quoted JS string literal. JSON uses double
    /// quotes, but a value may contain `'`, `\`, or the U+2028/U+2029 line terminators that are
    /// legal in JSON yet break a JS literal.
    static func escapeForJSStringLiteral(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count + 8)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func ensureGranted(api: String, session: ScriptSession) throws {
        guard let acceptable = Self.grantAliases[api] else { return } // ungated api
        guard !session.grants.isDisjoint(with: acceptable) else {
            throw BrownBearError.bridgeRejected("\(api) is not granted")
        }
    }

    // MARK: - getScripts

    private func handleGetScripts(payload: [String: Any],
                                  webView: WKWebView?,
                                  frameInfo: WKFrameInfo?) async throws -> [[String: Any]] {
        guard let urlString = payload["url"] as? String else {
            throw BrownBearError.bridgeRejected("missing url")
        }
        let isSubframe = (payload["isSubframe"] as? Bool) ?? false
        // The main frame loading means a new page (or a reload) — reap the web view's prior tokens so
        // they don't accumulate or get targeted by value broadcasts after their frames are gone.
        if !isSubframe, let webView { purgeSessions(for: webView) }
        let scripts = await scriptStore.enabledScripts()
        var result: [[String: Any]] = []
        for script in scripts {
            let meta = script.metadata
            guard meta.hasMatchingDirective else { continue }
            if isSubframe && meta.noFrames { continue }
            guard URLMatcher(metadata: meta).matches(urlString) else { continue }

            let token = UUID().uuidString
            var assetURLs = Set(meta.requires)
            assetURLs.formUnion(meta.resources.values)
            registerSession(token: token,
                            session: ScriptSession(id: script.id,
                                                   name: meta.displayName,
                                                   grants: Set(meta.effectiveGrants),
                                                   connects: meta.connects,
                                                   assetURLs: assetURLs,
                                                   webView: webView,
                                                   frameInfo: frameInfo))
            let values = await valueStore.snapshot(scriptID: script.id)
            result.append(Self.scriptPayload(script, token: token, values: values))
        }
        return result
    }

    private static func scriptPayload(_ script: UserScript, token: String, values: [String: String]) -> [String: Any] {
        let meta = script.metadata
        // Honor any per-script override (the "script settings" surface) over the declared directive,
        // so the runtime gates injection and picks the execution world by the effective values and
        // GM_info reflects what actually runs.
        let runAt = script.effectiveRunAt.rawValue
        let injectInto = script.effectiveInjectInto.rawValue
        let info: [String: Any] = [
            "scriptHandler": "BrownBear",
            "version": "0.1.0",
            "scriptMetaStr": meta.metadataBlock,
            "script": [
                "name": meta.name,
                "namespace": meta.namespace ?? "",
                "version": meta.version ?? "",
                "description": meta.descriptionText ?? "",
                "grant": meta.effectiveGrants,
                "connects": meta.connects,
                "runAt": runAt
            ]
        ]
        return [
            "token": token,
            "name": meta.name,
            "runAt": runAt,
            "grants": meta.effectiveGrants,
            "grantNone": meta.grantsNone,
            "noFrames": meta.noFrames,
            "injectInto": injectInto,
            "requires": meta.requires,
            "resources": meta.resources,
            "source": script.executableBody,
            "values": values,
            "info": info
        ]
    }

    // MARK: - GM_xmlhttpRequest

    private func handleXHR(payload: [String: Any],
                           session: ScriptSession,
                           frameURL: URL?,
                           webView: WKWebView?) async throws {
        guard let requestID = payload["requestId"] as? String,
              let request = payload["request"] as? [String: Any] else {
            throw BrownBearError.bridgeRejected("malformed xhr")
        }
        let declared = session.connects
        let pageHost = frameURL?.host
        let world = contentWorld
        weak var weakWebView = webView

        let emit: (String, [String: Any]) -> Void = { eventType, eventPayload in
            // Network events arrive on a background queue; deliver to JS on main IN ORDER.
            let args: [Any] = [requestID, eventType, eventPayload]
            guard let data = try? JSONSerialization.data(withJSONObject: args),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.__brownbear && window.__brownbear.dispatchXHR.apply(null, \(json));"
            DispatchQueue.main.async {
                // Via the Objective-C shim so we don't link the Swift WebKit overlay (see
                // BBWebKitBridge.h). Delivered FIFO on the main queue, in event order.
                if let webView = weakWebView { BBEvaluateJavaScript(webView, js, world) }
            }
        }

        // Resolve the @connect gate. Declared (or self/page) hosts proceed silently. An undeclared
        // host is allowed only if the user previously granted it, or grants it now at the prompt;
        // otherwise it is blocked and logged. The granted host is appended to the allowlist passed to
        // the network layer so the SAME-host redirect path validates too (redirects to OTHER
        // undeclared hosts are still blocked mid-flight — we never prompt for a redirect).
        var effectiveConnects = declared
        let targetHost = (request["url"] as? String).flatMap { URL(string: $0)?.host }
        if let host = targetHost,
           !GMNetworkService.isConnectAllowed(host: host, connects: declared, pageHost: pageHost) {
            let allowed = await resolveConnectDecision(scriptID: session.id,
                                                       scriptName: session.name,
                                                       host: host)
            guard allowed else {
                await logStore.append(LogEntry(scriptID: session.id,
                                               scriptName: session.name,
                                               level: .warn,
                                               message: "@connect blocked request to \(host)",
                                               context: .foreground))
                emit("error", ["error": "@connect blocked request to \(host)", "readyState": 4])
                emit("loadend", ["readyState": 4])
                return
            }
            effectiveConnects = declared + [host]
        }

        network.start(requestID: requestID, payload: request,
                      connects: effectiveConnects, pageHost: pageHost, emit: emit)
    }

    /// Decide whether `host` may be connected to for this script: a prior user grant proceeds
    /// silently; otherwise prompt once (concurrent requests to the same script+host share that one
    /// prompt) and persist an always-allow on Allow. Fails closed.
    private func resolveConnectDecision(scriptID: UUID, scriptName: String, host: String) async -> Bool {
        if await grantStore.isAllowed(scriptID: scriptID, host: host) { return true }

        let key = "\(scriptID.uuidString)|\(host.lowercased())"
        if let inFlight = pendingGrantDecisions[key] { return await inFlight.value }

        let grantStore = self.grantStore
        let task = Task { @MainActor () -> Bool in
            // Re-check inside the task in case a concurrent prompt already resolved+persisted.
            if await grantStore.isAllowed(scriptID: scriptID, host: host) { return true }
            let allow = await ConnectGrantPrompt.request(scriptName: scriptName, host: host)
            if allow { await grantStore.allow(scriptID: scriptID, host: host) }
            return allow
        }
        pendingGrantDecisions[key] = task
        let result = await task.value
        pendingGrantDecisions[key] = nil
        return result
    }
}
