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

    /// GM_notification in-app fallback: show a brief banner when the OS suppressed the notification
    /// (UN authorization denied). Best-effort UX so the notification isn't silently dropped.
    func bridgeShowNotificationFallback(title: String, body: String)

    /// GM.cookie.list — cookies matching the (already @connect-gated) chrome-shaped filter dict.
    func bridgeListCookies(filter: [String: Any]) async -> [[String: Any]]
    /// GM.cookie.set — create/overwrite a cookie from chrome setDetails; returns the stored cookie.
    func bridgeSetCookie(details: [String: Any]) async -> [String: Any]?
    /// GM.cookie.delete — delete the cookie matching name+url; returns the removal details, or nil.
    func bridgeDeleteCookie(url: String, name: String) async -> [String: Any]?

    /// GM_download — write `data` into the Downloads list under a unique destination; optionally
    /// present a share/save sheet (`presentSheet`). Returns the on-disk URL, or nil on write failure.
    func bridgeSaveDownload(data: Data, suggestedName: String, presentSheet: Bool) async -> URL?

    /// The chrome-style integer tab id of the tab backing `webView`, or nil if no tab owns it. Used by
    /// GM_getTab/GM_saveTab/GM_listTabs to key the per-tab object the same way chrome.tabs does — so a
    /// userscript and an extension agree on what "this tab" means. Resolved off the SAME registry.
    func bridgeTabId(for webView: WKWebView) -> Int?

    /// A script (re)registered or unregistered a GM menu command for `webView`. If that web view is the
    /// active tab and the "•••" menu is currently open, the browser rebuilds it so the command appears /
    /// disappears live. A no-op when no menu is showing.
    func bridgeMenuCommandsDidChange(in webView: WKWebView)
}

@MainActor
final class ScriptMessageRouter: NSObject, WKScriptMessageHandlerWithReply {

    /// The message handler name JS posts to: `window.webkit.messageHandlers.brownbear`.
    static let handlerName = "brownbear"

    /// The native-bound identity behind a token. Created in getScripts, looked up on every call.
    /// `fileprivate` (not `private`) so the same-file GM-handler extension can name it in the signatures
    /// of its `fileprivate` handlers (a `fileprivate` method may not take a `private`-typed parameter).
    fileprivate struct ScriptSession {
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

        /// A value-type projection handed to the same-module +Privileged extension (which cannot name
        /// this private type). Carries only what the privileged handlers need.
        var privileged: ScriptMessageRouter.PrivilegedSession {
            ScriptMessageRouter.PrivilegedSession(id: id, name: name, connects: connects,
                                                  webView: webView, frameInfo: frameInfo)
        }
    }

    private let scriptStore: ScriptStore
    private let valueStore: GMValueStore
    private let network: GMNetworkService
    private let logStore: LogStore
    private let contentWorld: WKContentWorld
    /// Per-script user grants for hosts not in `@connect` (ScriptCat-style allow-always).
    private let grantStore: ConnectGrantStore
    weak var host: ScriptBridgeHost?

    /// Backs GM_registerMenuCommand/GM_unregisterMenuCommand and GM_getTab/GM_saveTab/GM_listTabs.
    /// App-lifetime; entries are reaped alongside this router's sessions on (re)load (see
    /// purgeSessions) and when a tab closes (forgetTabObjects, called by the browser VC).
    let menuStore = UserScriptMenuCommandStore()

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
    /// Sessions purged on a main-frame load, kept (sans web view) so a document restored from WebKit's
    /// back-forward cache can revalidate its tokens — a bfcache restore does NOT re-run document-start
    /// scripts, so the restored page's userscripts keep running with tokens that purgeSessions dropped,
    /// and every GM_* call then failed "unrecognized or missing script token" on exactly the pages
    /// reached via back/forward. Identity (script id/grants/connects) is preserved HERE, natively; the
    /// loader can only revive tokens it already holds. Capped FIFO like `sessions`.
    private var purgedSessions: [String: ScriptSession] = [:]
    private var purgedOrder: [String] = []
    private static let maxPurgedSessions = 4096
    private static let maxRevalidateTokens = 256

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
        "GM_xmlhttpRequest": ["GM_xmlhttpRequest", "GM.xmlHttpRequest"],
        "GM_notification": ["GM_notification", "GM.notification"],
        "GM_cookie": ["GM_cookie", "GM.cookie", "GM.cookie.list", "GM.cookie.set", "GM.cookie.delete"],
        "GM_download": ["GM_download", "GM.download"],
        "GM_registerMenuCommand": ["GM_registerMenuCommand", "GM.registerMenuCommand"],
        "GM_unregisterMenuCommand": ["GM_unregisterMenuCommand", "GM.unregisterMenuCommand"],
        "GM_getTab": ["GM_getTab", "GM.getTab"],
        "GM_saveTab": ["GM_saveTab", "GM.saveTab"],
        "GM_listTabs": ["GM_listTabs", "GM.listTabs"]
    ]

    /// The menu/tab APIs, dispatched as a group in route() (before the main switch) so the switch's
    /// cyclomatic complexity doesn't grow with each one. Keep in sync with routeMenuOrTab.
    private static let menuTabAPIs: Set<String> = [
        "GM_registerMenuCommand", "GM_unregisterMenuCommand", "GM_getTab", "GM_saveTab", "GM_listTabs"
    ]

    /// The GM value-store APIs, dispatched as a group in route() (before the main switch) for the same
    /// cyclomatic-complexity reason as menuTabAPIs. Keep in sync with routeValueAPIs.
    private static let valueAPIs: Set<String> = [
        "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues", "GM_setValues", "GM_deleteValues"
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
        // Tokenless like getScripts: a back-forward-cache-restored document re-registering its purged
        // tokens (document-start scripts don't re-run on a bfcache restore, so getScripts can't). A
        // token revives ONLY if this router itself tombstoned it — identity comes from the tombstone,
        // never the caller; unknown tokens are ignored; the web view/frame re-bind to the CALLING frame.
        if api == "revalidateSessions" {
            return handleRevalidateSessions(payload: payload, webView: webView, frameInfo: frameInfo)
        }
        // GM_abortRequest only cancels the caller's own request by id — safe without a grant.
        if api == "GM_abortRequest" {
            if let requestID = payload["requestId"] as? String { network.abort(requestID: requestID) }
            return NSNull()
        }

        // Everything else requires a native-bound session and a grant.
        let session = try resolveSession(token)

        // Page-world execution is handled in a helper so route() stays within its cyclomatic-complexity
        // budget (it needs a valid session token but no GM grant — see handleInjectPageWorld).
        if api == "injectPageWorld" {
            return handleInjectPageWorld(payload: payload, webView: webView, frameInfo: frameInfo)
        }

        try ensureGranted(api: api, session: session)

        // The menu/tab and value-store APIs are each dispatched here, before the main switch, so route()
        // stays within its cyclomatic-complexity budget as the GM surface grows (each shares one sub-dispatch).
        if Self.menuTabAPIs.contains(api) {
            return try routeMenuOrTab(api: api, payload: payload, token: token, session: session, webView: webView)
        }
        if Self.valueAPIs.contains(api) {
            return try await routeValueAPIs(api: api, payload: payload, token: token, session: session)
        }

        switch api {
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

        case "GM_notification":
            return try await handleNotification(payload: payload, session: session.privileged)

        case "GM_notificationClear":
            return handleNotificationClear(payload: payload, session: session.privileged)

        case "GM_cookie":
            return try await handleCookie(payload: payload, session: session.privileged, frameURL: frameURL)

        case "GM_download":
            try await handleDownload(payload: payload, session: session.privileged,
                                     frameURL: frameURL, webView: webView)
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
            return try await fetchAsset(url, connects: session.connects)

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    /// Fetch a script asset (@require/@resource) natively. Returns text + base64 + mime so the
    /// runtime can serve both GM_getResourceText and GM_getResourceURL (as a data: URL).
    ///
    /// Backed by `GMAssetCache`: a previously-fetched asset is revalidated with a conditional GET
    /// (ETag / Last-Modified) so an unchanged require costs a 304 instead of a full download, and a
    /// network failure falls back to the last good copy — so a library-dependent script keeps working
    /// offline instead of silently loading an empty dependency. This is the Violentmonkey behavior
    /// (fetch-once, cache, revalidate) ported to the bridge fetch path.
    private func fetchAsset(_ url: URL, connects: [String]) async throws -> [String: Any] {
        let cached = await GMAssetCache.shared.entry(for: url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // We own the caching, so bypass URLSession's HTTP cache: this makes our conditional
        // validators reach the origin and a real 304 surface (rather than URLSession transparently
        // satisfying the request from its own store and hiding whether it changed).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        // Re-validate @connect on every redirect hop so a 3xx can't bounce the @require/@resource fetch
        // to an undeclared or internal host (SSRF). pageHost = the asset's own (declared) host, so the
        // first hop is implicitly allowed; any cross-host redirect needs an @connect grant.
        let redirectGuard = GMRedirectGuard(connects: connects, pageHost: url.host)
        do {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: redirectGuard)
            let http = response as? HTTPURLResponse
            // 304 Not Modified → the cached bytes are still current; serve them.
            if http?.statusCode == 304, let cached {
                return Self.assetPayload(data: cached.data, mime: cached.mimeType)
            }
            let mime = http?.value(forHTTPHeaderField: "Content-Type")
                ?? cached?.mimeType ?? "application/octet-stream"
            let entry = GMAssetCache.Entry(
                data: data,
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                mimeType: mime)
            await GMAssetCache.shared.store(entry, for: url)
            return Self.assetPayload(data: data, mime: mime)
        } catch {
            // Offline / transport failure: serve the last good copy if we have one, so a require that
            // loaded once keeps the script working. Only propagate when there is nothing to fall back on.
            if let cached {
                return Self.assetPayload(data: cached.data, mime: cached.mimeType)
            }
            throw error
        }
    }

    /// Shape fetched/cached asset bytes into the bridge payload the runtime expects (text + base64 +
    /// mime), so GM_getResourceText and GM_getResourceURL (a data: URL) both resolve.
    private static func assetPayload(data: Data, mime: String) -> [String: Any] {
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
                let json = JSONSanitize.string(payload)   // NaN/Inf-safe (uncatchable Obj-C exception otherwise)
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
            // A private/incognito tab is backed by a non-persistent WKWebsiteDataStore
            // (WebViewConfigurationFactory uses WKWebsiteDataStore.nonPersistent() for private tabs).
            // Surface it as GM_info.isIncognito so privacy-aware scripts can adapt. Defaults to false
            // when the web view is gone (shouldn't happen during getScripts, but fail to non-private).
            let isIncognito = webView.map { $0.configuration.websiteDataStore.isPersistent == false } ?? false
            result.append(Self.scriptPayload(script, token: token, values: values, isIncognito: isIncognito))
        }
        return result
    }

    /// The host/app version surfaced as `GM_info.version` (the userscript-manager version, NOT the
    /// script's own @version — that lives under `GM_info.script.version`). Tampermonkey parity.
    private static let handlerVersion: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    private static func scriptPayload(_ script: UserScript,
                                      token: String,
                                      values: [String: String],
                                      isIncognito: Bool) -> [String: Any] {
        let meta = script.metadata
        // Honor any per-script override (the "script settings" surface) over the declared directive,
        // so the runtime gates injection and picks the execution world by the effective values and
        // GM_info reflects what actually runs.
        let runAt = script.effectiveRunAt.rawValue
        let injectInto = script.effectiveInjectInto.rawValue

        // Whether THIS script will be picked up by the automatic update pass. Mirrors UpdateService
        // eligibility: a per-script override wins, else the global setting, and only scripts that
        // actually declare a download/update source are updatable. Surfaced as GM_info.scriptWillUpdate
        // (Tampermonkey/Violentmonkey parity).
        let hasUpdateSource = (meta.downloadURL?.isEmpty == false) || (meta.updateURL?.isEmpty == false)
        let scriptWillUpdate = hasUpdateSource && (script.overrides?.autoUpdate ?? AppSettings.autoUpdateScripts)

        let scriptObject = scriptSubObject(meta, runAt: runAt, scriptWillUpdate: scriptWillUpdate)
        let info = gmInfo(script, meta: meta, isIncognito: isIncognito, runAt: runAt,
                          injectInto: injectInto, scriptObject: scriptObject,
                          scriptWillUpdate: scriptWillUpdate)
        return [
            "token": token,
            "name": meta.name,
            "uuid": script.id.uuidString,
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

    /// The full `GM_info.script` sub-object Tampermonkey/Violentmonkey expose. Empty optionals become
    /// empty strings (never JS `undefined` over the bridge) so scripts can read fields uniformly.
    private static func scriptSubObject(_ meta: ScriptMetadata,
                                        runAt: String,
                                        scriptWillUpdate: Bool) -> [String: Any] {
        [
            "name": meta.name,
            "namespace": meta.namespace ?? "",
            "version": meta.version ?? "",
            "description": meta.descriptionText ?? "",
            "author": meta.author ?? "",
            "homepage": meta.homepageURL ?? "",
            "homepageURL": meta.homepageURL ?? "",
            "icon": meta.iconURL ?? "",
            "icon64": meta.iconURL ?? "",
            "updateURL": meta.updateURL ?? "",
            "downloadURL": meta.downloadURL ?? "",
            "supportURL": "",
            "grant": meta.effectiveGrants,
            "connects": meta.connects,
            "connect": meta.connects,
            "matches": meta.matches,
            "includes": meta.includes,
            "excludes": meta.excludes,
            "excludeMatches": meta.excludeMatches,
            "requires": meta.requires,
            "resources": meta.resources.map { ["name": $0.key, "url": $0.value] },
            "run-at": runAt,
            "runAt": runAt,
            "noframes": meta.noFrames,
            "unwrap": false,
            "header": meta.metadataBlock,
            "options": [
                "check_for_updates": scriptWillUpdate,
                "comment": NSNull(),
                "compatopts_for_requires": true,
                "compat_wrappedjsobject": false,
                "compat_metadata": false,
                "run_at": runAt,
                "override": [
                    "use_includes": meta.includes,
                    "use_matches": meta.matches,
                    "use_excludes": meta.excludes,
                    "use_connects": meta.connects
                ]
            ]
        ]
    }

    /// The top-level `GM_info` object. Built entirely from data the script itself declared plus
    /// app-known facts (handler version, incognito) — no cross-script leakage.
    private static func gmInfo(_ script: UserScript,
                               meta: ScriptMetadata,
                               isIncognito: Bool,
                               runAt: String,
                               injectInto: String,
                               scriptObject: [String: Any],
                               scriptWillUpdate: Bool) -> [String: Any] {
        [
            "uuid": script.id.uuidString,
            "scriptHandler": "BrownBear",
            "version": Self.handlerVersion,
            "scriptMetaStr": meta.metadataBlock,
            "scriptUpdateURL": meta.updateURL ?? meta.downloadURL ?? "",
            "scriptWillUpdate": scriptWillUpdate,
            "scriptSource": script.source,
            "downloadMode": "native",
            "isIncognito": isIncognito,
            "sandboxMode": "js",
            "injectInto": injectInto,
            "runAt": runAt,
            // A private/incognito session uses an ephemeral data store; a normal session shares the
            // default container. ScriptCat/TM expose `container` so value-store scoping is visible.
            "container": isIncognito ? "incognito" : "default",
            "platform": [
                "arch": "arm64",
                "browserName": "BrownBear",
                "browserVersion": Self.handlerVersion,
                "os": "ios"
            ],
            "script": scriptObject
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
            let json = JSONSanitize.string(args)   // NaN/Inf-safe (uncatchable Obj-C exception otherwise)
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
                      connects: effectiveConnects, pageHost: pageHost,
                      scriptName: session.name, emit: emit)
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

    // MARK: - Privileged-extension bridging shims
    //
    // The host-reaching GM apis (GM_notification / GM_cookie / GM_download) live in
    // ScriptMessageRouter+Privileged.swift (kept separate so this type stays under the
    // type_body_length limit). A cross-file extension cannot touch `private` members, so we expose
    // exactly what it needs here as `internal`, and nothing more.

    /// A flattened, value-type view of a ScriptSession for the privileged extension (which can't name
    /// the private `ScriptSession` type).
    struct PrivilegedSession {
        let id: UUID
        let name: String
        let connects: [String]
        weak var webView: WKWebView?
        var frameInfo: WKFrameInfo?
    }

    /// The content world all BrownBear injection runs in — for pushing notification/download events
    /// back into the exact isolated world the script lives in.
    var privilegedContentWorld: WKContentWorld { contentWorld }

    /// The browser host — cookie I/O, the download save sheet, and the notification fallback toast.
    var privilegedHost: ScriptBridgeHost? { host }

    /// Append a foreground log line (used when @connect blocks a privileged host).
    func privilegedLog(scriptID: UUID, scriptName: String, message: String) async {
        await logStore.append(LogEntry(scriptID: scriptID, scriptName: scriptName,
                                       level: .warn, message: message, context: .foreground))
    }

    /// Reuse the XHR @connect decision (prompt-once + persist always-allow) for the cookie/download
    /// host gate.
    func resolvePrivilegedConnectDecision(scriptID: UUID, scriptName: String, host: String) async -> Bool {
        await resolveConnectDecision(scriptID: scriptID, scriptName: scriptName, host: host)
    }
}

// MARK: - Session lifecycle (split into an extension to keep the class body under type_body_length)
extension ScriptMessageRouter {

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
    /// Purged sessions are TOMBSTONED (web view + frame detached, identity kept), because the prior
    /// document usually enters WebKit's back-forward cache alive — see `purgedSessions`.
    private func purgeSessions(for webView: WKWebView) {
        // Menu commands are bound to the same injections; reap them with the sessions so a stale
        // "Script commands" entry can't survive a navigation/reload of this web view. Done first and
        // unconditionally — a main-frame (re)load means the registering page is gone even if its
        // sessions were already evicted by the FIFO cap.
        menuStore.purge(webView: webView)
        let stale = Set(sessions.compactMap { $0.value.webView === webView ? $0.key : nil })
        guard !stale.isEmpty else { return }
        for token in stale {
            guard var session = sessions.removeValue(forKey: token) else { continue }
            session.webView = nil
            session.frameInfo = nil
            purgedSessions[token] = session
            purgedOrder.append(token)
        }
        while purgedOrder.count > Self.maxPurgedSessions {
            purgedSessions.removeValue(forKey: purgedOrder.removeFirst())
        }
        tokenOrder.removeAll { stale.contains($0) }
    }

    /// Re-register a bfcache-restored document's purged sessions; see the `revalidateSessions` route.
    /// Returns how many tokens were revived (diagnostic value for the loader, not used for control flow).
    private func handleRevalidateSessions(payload: [String: Any],
                                          webView: WKWebView?,
                                          frameInfo: WKFrameInfo?) -> Int {
        guard let tokens = payload["tokens"] as? [String], !tokens.isEmpty else { return 0 }
        var restored = 0
        for token in tokens.prefix(Self.maxRevalidateTokens) {
            if sessions[token] != nil { continue }   // never purged (or already revived) — leave it be
            guard var session = purgedSessions.removeValue(forKey: token) else { continue }
            session.webView = webView
            session.frameInfo = frameInfo
            registerSession(token: token, session: session)
            restored += 1
        }
        if restored > 0 { purgedOrder.removeAll { purgedSessions[$0] == nil } }
        return restored
    }

}

// MARK: - GM_registerMenuCommand / GM_getTab / GM_saveTab / GM_listTabs handlers
//
// Kept in a same-file extension so they can reach the router's private store/contentWorld while not
// inflating the main type body. Every payload field is validated; missing/oversized input fails closed.
extension ScriptMessageRouter {

    /// Page-world execution: the isolated-world runtime asks native to evaluate a grant-none userscript
    /// in the calling frame's REAL main world (WKContentWorld.page), so `window`/`unsafeWindow` are the
    /// page's own globals (@grant none / @inject-into page — Tampermonkey parity). Like the extension
    /// runtime's page.injectMainWorld, native eval is CSP-immune (unlike an inline <script>). The caller
    /// (route) has already resolved a valid session token, which is the trust anchor — a grant-none
    /// script has no GM surface, so no further grant is needed — and this handler is registered ONLY in
    /// the isolated world, so a page script can never reach it.
    fileprivate func handleInjectPageWorld(payload: [String: Any],
                                           webView: WKWebView?, frameInfo: WKFrameInfo?) -> Any? {
        if let webView, let code = payload["code"] as? String, !code.isEmpty {
            BBEvaluateJavaScriptInFrame(webView, code, frameInfo, .page)
        }
        return NSNull()
    }

    /// Sub-dispatch for the six GM value-store APIs, collapsed under one `route()` case to keep that
    /// function's cyclomatic complexity within the SwiftLint budget. All six have already passed
    /// resolveSession + ensureGranted in route(). Bodies are unchanged from the original inline cases.
    fileprivate func routeValueAPIs(api: String, payload: [String: Any], token: String?,
                                    session: ScriptSession) async throws -> Any? {
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

        default:
            return NSNull()
        }
    }

    /// Sub-dispatch for the five menu/tab APIs, collapsed under one `route()` case to keep that
    /// function's cyclomatic complexity within the SwiftLint budget. All five have already passed
    /// resolveSession + ensureGranted in route().
    fileprivate func routeMenuOrTab(api: String, payload: [String: Any], token: String?,
                                    session: ScriptSession, webView: WKWebView?) throws -> Any? {
        switch api {
        case "GM_registerMenuCommand":
            return try handleRegisterMenuCommand(payload: payload, token: token, session: session, webView: webView)
        case "GM_unregisterMenuCommand":
            return handleUnregisterMenuCommand(payload: payload, token: token, session: session, webView: webView)
        case "GM_getTab":
            return try handleGetTab(session: session, webView: webView)
        case "GM_saveTab":
            return try handleSaveTab(payload: payload, session: session, webView: webView)
        case "GM_listTabs":
            return handleListTabs(session: session)
        default:
            return NSNull()
        }
    }

    fileprivate func handleRegisterMenuCommand(payload: [String: Any],
                                               token: String?,
                                               session: ScriptSession,
                                               webView: WKWebView?) throws -> Any? {
        guard let token, let webView else {
            throw BrownBearError.bridgeRejected("menu command needs a live injection")
        }
        guard let commandID = payload["commandId"] as? String, !commandID.isEmpty,
              let title = payload["title"] as? String, !title.isEmpty else {
            throw BrownBearError.bridgeRejected("missing menu command id/title")
        }
        // Clamp the caption so a malicious script can't blow up the menu layout.
        let clampedTitle = title.count > 200 ? String(title.prefix(200)) + "\u{2026}" : title
        var accessKey = payload["accessKey"] as? String
        if let key = accessKey, key.count > 1 { accessKey = String(key.prefix(1)) }
        let autoClose = (payload["autoClose"] as? Bool) ?? true
        menuStore.registerCommand(UserScriptMenuCommand(scriptID: session.id,
                                                        scriptName: session.name,
                                                        token: token,
                                                        commandID: commandID,
                                                        title: clampedTitle,
                                                        accessKey: accessKey,
                                                        autoClose: autoClose,
                                                        webView: webView,
                                                        frameInfo: session.frameInfo))
        host?.bridgeMenuCommandsDidChange(in: webView)
        // GM_registerMenuCommand returns the (possibly script-supplied) id, so the script can later
        // GM_unregisterMenuCommand it (Tampermonkey parity).
        return commandID
    }

    fileprivate func handleUnregisterMenuCommand(payload: [String: Any],
                                                 token: String?,
                                                 session: ScriptSession,
                                                 webView: WKWebView?) -> Any? {
        guard let token, let commandID = payload["commandId"] as? String else { return NSNull() }
        menuStore.unregisterCommand(token: token, commandID: commandID)
        if let webView { host?.bridgeMenuCommandsDidChange(in: webView) }
        return NSNull()
    }

    fileprivate func handleGetTab(session: ScriptSession, webView: WKWebView?) throws -> Any? {
        guard let webView, let tabID = host?.bridgeTabId(for: webView) else {
            // No resolvable tab (headless / closing) — hand back an empty object, never fail the script.
            return NSNull()
        }
        // Return the raw JSON string; the runtime parses it (it's the script's own serialized object).
        return menuStore.tabObject(tabID: tabID, scriptID: session.id) ?? NSNull()
    }

    fileprivate func handleSaveTab(payload: [String: Any],
                                   session: ScriptSession,
                                   webView: WKWebView?) throws -> Any? {
        guard let json = payload["value"] as? String else {
            throw BrownBearError.bridgeRejected("missing tab object")
        }
        guard let webView, let tabID = host?.bridgeTabId(for: webView) else { return NSNull() }
        guard menuStore.saveTabObject(tabID: tabID, scriptID: session.id, json: json) else {
            throw BrownBearError.bridgeRejected("tab object too large")
        }
        return NSNull()
    }

    fileprivate func handleListTabs(session: ScriptSession) -> Any? {
        // chrome tab id (as a string key, since JS object keys are strings) → the script's saved JSON.
        let objects = menuStore.tabObjects(forScript: session.id)
        var out: [String: String] = [:]
        for (tabID, json) in objects { out[String(tabID)] = json }
        return out
    }

    /// Called by the browser when a tab closes, so its per-tab GM objects don't outlive it (and a
    /// reused chrome id can't surface another tab's data). Routed via InjectionOrchestrator.
    func forgetTabObjects(tabID: Int) {
        menuStore.forgetTab(tabID: tabID)
    }

    /// Fire a registered menu command's callback back into the EXACT frame/world the registering script
    /// runs in. Called by the browser when the user taps the command in the menu. No-op if the command
    /// was unregistered or its web view died (fail closed). Returns true if a live command was fired.
    @discardableResult
    func fireMenuCommand(token: String, commandID: String) -> Bool {
        guard let command = menuStore.command(token: token, commandID: commandID),
              let webView = command.webView else { return false }
        let tokenLiteral = Self.escapeForJSStringLiteral(token)
        let idLiteral = Self.escapeForJSStringLiteral(commandID)
        let js = "window.__brownbear&&window.__brownbear.fireMenuCommand('\(tokenLiteral)','\(idLiteral)');"
        BBEvaluateJavaScriptInFrame(webView, js, command.frameInfo, contentWorld)
        return true
    }

    /// The active tab's live menu commands (registration order), for the browser to build the menu's
    /// "Script commands" section. Resolved off the calling web view so iframe registrations show too.
    func menuCommands(in webView: WKWebView) -> [UserScriptMenuCommand] {
        menuStore.commands(in: webView)
    }
}
