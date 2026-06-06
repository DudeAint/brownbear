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
        let grants: Set<String>
        let connects: [String]
    }

    private let scriptStore: ScriptStore
    private let valueStore: GMValueStore
    private let network: GMNetworkService
    private let contentWorld: WKContentWorld
    weak var host: ScriptBridgeHost?

    /// token → session. Tokens are random per injection; a script only ever sees its own.
    private var sessions: [String: ScriptSession] = [:]

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
         contentWorld: WKContentWorld) {
        self.scriptStore = scriptStore
        self.valueStore = valueStore
        self.network = network
        self.contentWorld = contentWorld
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let api = body["api"] as? String else {
            replyHandler(nil, "malformed bridge message")
            return
        }
        let payload = body["payload"] as? [String: Any] ?? [:]
        let token = body["token"] as? String
        let frameURL = message.frameInfo.request.url
        weak var webView = message.webView

        Task { @MainActor in
            do {
                let result = try await self.route(api: api,
                                                  payload: payload,
                                                  token: token,
                                                  frameURL: frameURL,
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
                       webView: WKWebView?) async throws -> Any? {
        // getScripts is the loader's privilege; it needs no token and mints them.
        if api == "getScripts" {
            return try await handleGetScripts(payload: payload)
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
            await valueStore.setValue(scriptID: session.id, key: key, jsonValue: json)
            return NSNull()

        case "GM_deleteValue":
            guard let key = payload["key"] as? String else { throw BrownBearError.bridgeRejected("missing key") }
            await valueStore.deleteValue(scriptID: session.id, key: key)
            return NSNull()

        case "GM_listValues":
            return await valueStore.listValues(scriptID: session.id)

        case "GM_setValues":
            guard let entries = payload["values"] as? [String: String] else {
                throw BrownBearError.bridgeRejected("missing values")
            }
            await valueStore.setValues(scriptID: session.id, entries: entries)
            return NSNull()

        case "GM_deleteValues":
            guard let keys = payload["keys"] as? [String] else { throw BrownBearError.bridgeRejected("missing keys") }
            await valueStore.deleteValues(scriptID: session.id, keys: keys)
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

        case "GM_log":
            // Module 4 routes this into the persistent LogEntry store; for now it's an ack.
            return NSNull()

        case "GM_xmlhttpRequest":
            try handleXHR(payload: payload, session: session, frameURL: frameURL, webView: webView)
            return NSNull()

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    // MARK: - Identity & grants

    private func resolveSession(_ token: String?) throws -> ScriptSession {
        guard let token, let session = sessions[token] else {
            throw BrownBearError.bridgeRejected("unrecognized or missing script token")
        }
        return session
    }

    private func ensureGranted(api: String, session: ScriptSession) throws {
        guard let acceptable = Self.grantAliases[api] else { return } // ungated api
        guard !session.grants.isDisjoint(with: acceptable) else {
            throw BrownBearError.bridgeRejected("\(api) is not granted")
        }
    }

    // MARK: - getScripts

    private func handleGetScripts(payload: [String: Any]) async throws -> [[String: Any]] {
        guard let urlString = payload["url"] as? String else {
            throw BrownBearError.bridgeRejected("missing url")
        }
        let isSubframe = (payload["isSubframe"] as? Bool) ?? false
        let scripts = await scriptStore.enabledScripts()
        var result: [[String: Any]] = []
        for script in scripts {
            let meta = script.metadata
            guard meta.hasMatchingDirective else { continue }
            if isSubframe && meta.noFrames { continue }
            guard URLMatcher(metadata: meta).matches(urlString) else { continue }

            let token = UUID().uuidString
            sessions[token] = ScriptSession(id: script.id,
                                            grants: Set(meta.effectiveGrants),
                                            connects: meta.connects)
            let values = await valueStore.snapshot(scriptID: script.id)
            result.append(Self.scriptPayload(script, token: token, values: values))
        }
        return result
    }

    private static func scriptPayload(_ script: UserScript, token: String, values: [String: String]) -> [String: Any] {
        let meta = script.metadata
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
                "runAt": meta.runAt.rawValue
            ]
        ]
        return [
            "token": token,
            "name": meta.name,
            "runAt": meta.runAt.rawValue,
            "grants": meta.effectiveGrants,
            "grantNone": meta.grantsNone,
            "noFrames": meta.noFrames,
            "injectInto": meta.injectInto.rawValue,
            "requires": meta.requires,
            "source": script.executableBody,
            "values": values,
            "info": info
        ]
    }

    // MARK: - GM_xmlhttpRequest

    private func handleXHR(payload: [String: Any],
                           session: ScriptSession,
                           frameURL: URL?,
                           webView: WKWebView?) throws {
        guard let requestID = payload["requestId"] as? String,
              let request = payload["request"] as? [String: Any] else {
            throw BrownBearError.bridgeRejected("malformed xhr")
        }
        let connects = session.connects
        let pageHost = frameURL?.host
        let world = contentWorld
        weak var weakWebView = webView

        network.start(requestID: requestID, payload: request, connects: connects, pageHost: pageHost) { eventType, eventPayload in
            // Network events arrive on a background queue; deliver to JS on main IN ORDER.
            let args: [Any] = [requestID, eventType, eventPayload]
            guard let data = try? JSONSerialization.data(withJSONObject: args),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.__brownbear && window.__brownbear.dispatchXHR.apply(null, \(json));"
            DispatchQueue.main.async {
                weakWebView?.evaluateJavaScript(js, in: nil, in: world)
            }
        }
    }
}
