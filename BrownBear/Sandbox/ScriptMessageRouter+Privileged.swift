//
//  ScriptMessageRouter+Privileged.swift
//  BrownBear
//
//  The host-reaching GM_* handlers — GM_notification, GM_cookie (GM.cookie list/set/delete), and
//  GM_download — split into a cross-file extension to keep ScriptMessageRouter.swift under SwiftLint's
//  type_body_length limit. A cross-file extension cannot see the primary type's `private` members, so
//  it calls the thin `internal` shims the router exposes (privilegedHost, privilegedContentWorld,
//  privilegedLog, resolvePrivilegedConnectDecision) and the value-type `PrivilegedSession`.
//
//  Gating (CLAUDE.md §5): each api is grant-gated by ensureGranted (in route(), before dispatch).
//  Beyond the grant, the host a cookie touches and the URL a download fetches are @connect-gated
//  EXACTLY like GM_xmlhttpRequest — GMNetworkService.isConnectAllowed + the ConnectGrantStore prompt —
//  so a script can't read/write cookies for, or pull bytes from, a host it never declared (and the
//  user never allowed). Fails closed.
//

import UIKit
import WebKit

extension ScriptMessageRouter {

    // MARK: - Page-world write handler (brownbearPage)

    /// The RESTRICTED handler registered in the PAGE world (`WKContentWorld.page`). A granted page-world
    /// userscript reaches it via the document-start vault's `window.__bbPageGM(token, api, payload)` to
    /// persist its OWN-DATA writes. Messages on this name are gated to `pageWorldWriteAPIs` ONLY (the
    /// `fromPageWorld` guard in `route`) — never getScripts, injectPageWorld, or any cross-origin API. The
    /// page world holds no token of its own, so a hostile page calling it directly fails at `resolveSession`.
    static let pageHandlerName = "brownbearPage"

    /// The exhaustive allowlist a page-world caller may invoke: a script's OWN-DATA writes, `log`, the
    /// network `GM_xmlhttpRequest`/`GM_abortRequest` and `GM_download`/`GM_downloadAbort` (lifecycle streamed
    /// native→page via window.__bbPageXHR; both @connect-gated per the token), the menu APIs
    /// `GM_registerMenuCommand`/`GM_unregisterMenuCommand` and `GM_openInTab`/`GM_closeTab` (a tap / a tab
    /// close streams native→page via the same channel), and the request→reply APIs
    /// `GM_cookie`/`GM_getTab`/`GM_saveTab`/`GM_listTabs` (their result is RETURNED through the
    /// WKScriptMessageHandlerWithReply reply promise — never on the DOM). Anything not here (getScripts,
    /// injectPageWorld, notifications, and reads — served page-local) is rejected for page-world callers.
    static let pageWorldWriteAPIs: Set<String> = [
        "GM_setValue", "GM_deleteValue", "GM_setValues", "GM_deleteValues", "GM_setClipboard", "GM_log", "log",
        "GM_xmlhttpRequest", "GM_abortRequest", "GM_download", "GM_downloadAbort",
        "GM_registerMenuCommand", "GM_unregisterMenuCommand", "GM_openInTab", "GM_closeTab",
        "GM_cookie", "GM_getTab", "GM_saveTab", "GM_listTabs"
    ]

    // MARK: - GM_openInTab close notification

    /// Notify a GM_openInTab handle that the tab it opened has closed — flips `.closed` and fires
    /// `onclose` — dispatched into the OPENER's frame + isolated world (iframe-aware). Internal (not
    /// private) so the router's GM_openInTab handler can call it across the file boundary; takes only
    /// primitives, so it never needs the fileprivate ScriptSession.
    func dispatchTabClosed(openId: String, webView: WKWebView?, frame: WKFrameInfo?,
                           world: WKContentWorld, isPageWorld: Bool = false) {
        guard let webView else { return }
        let idLiteral = Self.escapeForJSStringLiteral(openId)
        // A page-world opener streams the close back via the vault's minted-id channel (window.__bbPageXHR,
        // native→page eval) into .page — routed to the handler registered under this openId — never the
        // isolated __brownbear dispatcher. The world passed in is already .page for that case.
        let js = isPageWorld
            ? "window.__bbPageXHR && window.__bbPageXHR('\(idLiteral)','close',{});"
            : "window.__brownbear && window.__brownbear.dispatchTabClosed && "
                + "window.__brownbear.dispatchTabClosed('\(idLiteral)');"
        BBEvaluateJavaScriptInFrame(webView, js, frame, world)
    }

    // MARK: - GM_download cancellation

    /// Register a cancel closure for an in-flight GM_download so GM_downloadAbort can stop it. Called by
    /// handleDownload when the fetch starts; cleared by finishDownload. If an abort already raced ahead
    /// (e.g. fired during the @connect prompt), cancel immediately rather than start.
    func registerDownloadCancel(_ cancel: @escaping () -> Void, for requestID: String) {
        if pendingDownloadAborts.remove(requestID) != nil {
            cancel()
            return
        }
        downloadCancels[requestID] = cancel
    }

    /// Drop a finished/failed download's cancel entry. Called when handleDownload settles.
    func finishDownload(_ requestID: String) {
        downloadCancels.removeValue(forKey: requestID)
        pendingDownloadAborts.remove(requestID)
    }

    /// Cancel an in-flight download (GM_downloadAbort). If the fetch hasn't registered its canceller yet
    /// (the abort raced its @connect prompt), remember it so registerDownloadCancel cancels on arrival.
    func cancelDownload(requestID: String) {
        if let cancel = downloadCancels.removeValue(forKey: requestID) {
            cancel()
        } else {
            pendingDownloadAborts.insert(requestID)
        }
    }

    // MARK: - GM_notification

    /// GM_notification: post a local banner attributed to this script; route a tap back to its
    /// content world as the onclick callback. No host reached, so only the grant gates it. Returns
    /// { id, shown } so the runtime's control object can later remove it.
    func handleNotification(payload: [String: Any], session: PrivilegedSession) async throws -> Any? {
        let details = (payload["details"] as? [String: Any]) ?? [:]
        let notificationID = payload["id"] as? String
        let wantClick = (payload["wantClick"] as? Bool) ?? false
        let target = UserScriptNotificationTarget(scriptID: session.id,
                                                  scriptName: session.name,
                                                  webView: session.webView,
                                                  frameInfo: session.frameInfo,
                                                  contentWorld: privilegedContentWorld)
        let result = await UserScriptNotificationManager.shared.create(target: target,
                                                                       notificationID: notificationID,
                                                                       options: details,
                                                                       wantClick: wantClick)
        if !result.shown {
            // In-app fallback when the OS suppressed the banner (auth denied): surface a toast so the
            // notification isn't silently lost. Best-effort — the id is still returned either way.
            let title = (details["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session.name
            let text = (details["text"] as? String) ?? (details["message"] as? String) ?? ""
            privilegedHost?.bridgeShowNotificationFallback(title: title, body: text)
        }
        return ["id": result.id, "shown": result.shown]
    }

    /// GM_notification(...).remove() — clear a notification this script created (scoped to session.id).
    func handleNotificationClear(payload: [String: Any], session: PrivilegedSession) -> Any? {
        guard let id = payload["id"] as? String, !id.isEmpty else { return false }
        return UserScriptNotificationManager.shared.clear(scriptID: session.id, notificationID: id)
    }

    // MARK: - GM_cookie (GM.cookie.list/set/delete)

    /// GM_cookie(action, details). `action` is "list" | "set" | "delete". The cookie host (from
    /// details.url, or derived from details.domain) is @connect-gated before any jar I/O. The
    /// value↔chrome-shape mapping happens in the browser host (which reuses WebExtensionCookieMapper).
    func handleCookie(payload: [String: Any], session: PrivilegedSession, frameURL: URL?) async throws -> Any? {
        guard let action = payload["action"] as? String else {
            throw BrownBearError.bridgeRejected("missing cookie action")
        }
        let details = (payload["details"] as? [String: Any]) ?? [:]
        guard let host = Self.cookieHost(from: details) else {
            throw BrownBearError.bridgeRejected("GM_cookie requires a url or domain")
        }
        try await ensurePrivilegedConnect(host: host, session: session, frameURL: frameURL)

        guard let bridgeHost = privilegedHost else {
            throw BrownBearError.bridgeRejected("cookie host unavailable")
        }
        switch action {
        case "list":
            return await bridgeHost.bridgeListCookies(filter: Self.cookieFilter(from: details))
        case "set":
            return await bridgeHost.bridgeSetCookie(details: details) ?? NSNull()
        case "delete":
            guard let url = Self.cookieURLString(from: details) else {
                throw BrownBearError.bridgeRejected("GM_cookie delete requires a url or domain")
            }
            let name = (details["name"] as? String) ?? ""
            return await bridgeHost.bridgeDeleteCookie(url: url, name: name) ?? NSNull()
        default:
            throw BrownBearError.bridgeRejected("unsupported cookie action '\(action)'")
        }
    }

    /// The host a cookie operation touches: prefer an explicit `url`, else fall back to `domain`.
    private static func cookieHost(from details: [String: Any]) -> String? {
        if let urlString = details["url"] as? String, let url = URL(string: urlString), let host = url.host {
            return host
        }
        if let domain = details["domain"] as? String, !domain.isEmpty {
            return domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        }
        return nil
    }

    private static func cookieURLString(from details: [String: Any]) -> String? {
        if let url = details["url"] as? String, !url.isEmpty { return url }
        guard let domain = details["domain"] as? String, !domain.isEmpty else { return nil }
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let path = (details["path"] as? String) ?? "/"
        return "https://\(bare)\(path.hasPrefix("/") ? path : "/" + path)"
    }

    /// Build a chrome.cookies.getAll-shaped filter from GM.cookie.list details (only the keys the
    /// host's matcher understands).
    private static func cookieFilter(from details: [String: Any]) -> [String: Any] {
        var filter: [String: Any] = [:]
        for key in ["url", "name", "domain", "path"] {
            if let value = details[key] as? String, !value.isEmpty { filter[key] = value }
        }
        if let secure = details["secure"] as? Bool { filter["secure"] = secure }
        if let session = details["session"] as? Bool { filter["session"] = session }
        return filter
    }

    // MARK: - GM_download

    /// GM_download(details). Fetches `details.url` on a native URLSession (bypassing page CORS) after
    /// @connect-gating the URL host, re-validates the FINAL host after redirects, streams done/error
    /// back to the script over the same dispatch shape as XHR, writes the file into
    /// Documents/Downloads (so it shows in the Downloads list), and optionally presents a share/save
    /// sheet via the host. `requestId` correlates the events.
    func handleDownload(payload: [String: Any], session: PrivilegedSession,
                        frameURL: URL?, webView: WKWebView?, fromPageWorld: Bool = false) async throws {
        guard let requestID = payload["requestId"] as? String,
              let urlString = payload["url"] as? String,
              let url = URL(string: urlString) else {
            throw BrownBearError.bridgeRejected("GM_download requires requestId and url")
        }
        guard let host = url.host else { throw BrownBearError.bridgeRejected("GM_download url has no host") }
        let derivedName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let name = (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? derivedName
        let headers = (payload["headers"] as? [String: String]) ?? [:]
        let saveAs = (payload["saveAs"] as? Bool) ?? false
        let timeoutMs = payload["timeout"] as? Double

        try await ensurePrivilegedConnect(host: host, session: session, frameURL: frameURL)

        // A page-world download streams to .page via the non-configurable window.__bbPageXHR (native→page
        // eval, NOT a DOM channel), routed to the vault-registered handler for this minted requestID —
        // exactly like a page-world GM_xmlhttpRequest. The isolated world uses __brownbear.dispatchDownload.
        let world = fromPageWorld ? WKContentWorld.page : privilegedContentWorld
        weak var weakWebView = webView
        let emit: (String, [String: Any]) -> Void = { eventType, eventPayload in
            let args: [Any] = [requestID, eventType, eventPayload]
            guard let data = try? JSONSerialization.data(withJSONObject: args),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = fromPageWorld
                ? "window.__bbPageXHR && window.__bbPageXHR.apply(null, \(json));"
                : "window.__brownbear && window.__brownbear.dispatchDownload && window.__brownbear.dispatchDownload.apply(null, \(json));"
            DispatchQueue.main.async {
                if let webView = weakWebView { BBEvaluateJavaScript(webView, js, world) }
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let timeoutMs, timeoutMs > 0 { request.timeoutInterval = timeoutMs / 1000.0 }

        // Run the fetch in a child task so GM_downloadAbort can cancel it mid-transfer (the async
        // URLSession call is cancellation-aware → throws URLError.cancelled). Registered by requestId
        // and cleared when we settle, exactly like network.abort does for GM_xmlhttpRequest.
        let fetchTask = Task { try await Self.downloadSession.data(for: request) }
        registerDownloadCancel({ fetchTask.cancel() }, for: requestID)
        defer { finishDownload(requestID) }

        do {
            let (data, response) = try await fetchTask.value
            // Re-validate the FINAL host (after any redirects URLSession followed) against @connect; a
            // declared host must not be able to bounce the fetch to an undeclared one.
            let finalHost = (response.url ?? url).host
            let finalAllowed = GMNetworkService.isConnectAllowed(host: finalHost,
                                                                connects: session.connects,
                                                                pageHost: frameURL?.host)
                || (finalHost.map { $0.caseInsensitiveCompare(host) == .orderedSame } ?? false)
            guard finalAllowed else {
                emit("error", ["error": "@connect blocked download redirect to \(finalHost ?? "host")"])
                return
            }
            let localURL = await privilegedHost?.bridgeSaveDownload(data: data,
                                                                    suggestedName: name,
                                                                    presentSheet: saveAs)
            emit("load", [
                "finalUrl": (response.url ?? url).absoluteString,
                "total": data.count,
                "loaded": data.count,
                "localPath": localURL?.path ?? ""
            ])
        } catch let error as NSError {
            if error.code == NSURLErrorCancelled {
                emit("abort", ["error": "aborted"])
            } else if error.code == NSURLErrorTimedOut {
                emit("timeout", ["error": error.localizedDescription])
            } else {
                emit("error", ["error": error.localizedDescription])
            }
        }
    }

    /// @connect-gate a host for a privileged GM api (cookie/download), reusing the XHR decision path:
    /// declared/self/page hosts proceed silently; an undeclared host is allowed only if previously
    /// granted or granted now at the one-shot prompt; otherwise it throws (fail closed) and logs.
    private func ensurePrivilegedConnect(host: String, session: PrivilegedSession, frameURL: URL?) async throws {
        if GMNetworkService.isConnectAllowed(host: host, connects: session.connects, pageHost: frameURL?.host) {
            return
        }
        let allowed = await resolvePrivilegedConnectDecision(scriptID: session.id,
                                                             scriptName: session.name,
                                                             host: host)
        guard allowed else {
            await privilegedLog(scriptID: session.id, scriptName: session.name,
                                message: "@connect blocked access to \(host)")
            throw BrownBearError.bridgeRejected("@connect does not permit \(host)")
        }
    }

    /// A URLSession dedicated to GM_download. Ephemeral so it doesn't pollute the shared jar; cookies
    /// off (a download is not credentialed unless the script set headers explicitly).
    fileprivate static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    // MARK: - GM_registerMenuCommand fire / list
    //
    // Live next to the menu handlers (and out of ScriptMessageRouter.swift, which is at its file_length
    // budget). `privilegedContentWorld` is this router's isolated content world (the same `contentWorld`).

    /// Fire a registered menu command's callback back into the EXACT frame/world the registering script
    /// runs in. Called by the browser when the user taps the command in the menu. No-op if the command was
    /// unregistered or its web view died (fail closed). Returns true if a live command was fired.
    @discardableResult
    func fireMenuCommand(token: String, commandID: String) -> Bool {
        guard let command = menuStore.command(token: token, commandID: commandID),
              let webView = command.webView else { return false }
        let idLiteral = Self.escapeForJSStringLiteral(commandID)
        if command.isPageWorld {
            // Page-world command: stream the tap back via the vault's minted-id channel into .page, routed
            // to the handler registered under this command id — never the isolated __brownbear dispatcher.
            let js = "window.__bbPageXHR&&window.__bbPageXHR('\(idLiteral)','menu',{});"
            BBEvaluateJavaScriptInFrame(webView, js, command.frameInfo, WKContentWorld.page)
            return true
        }
        let tokenLiteral = Self.escapeForJSStringLiteral(token)
        let js = "window.__brownbear&&window.__brownbear.fireMenuCommand('\(tokenLiteral)','\(idLiteral)');"
        BBEvaluateJavaScriptInFrame(webView, js, command.frameInfo, privilegedContentWorld)
        return true
    }

    /// The active tab's live menu commands (registration order), for the browser to build the menu's
    /// "Script commands" section. Resolved off the calling web view so iframe registrations show too.
    func menuCommands(in webView: WKWebView) -> [UserScriptMenuCommand] {
        menuStore.commands(in: webView)
    }
}
