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
                        frameURL: URL?, webView: WKWebView?) async throws {
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

        let world = privilegedContentWorld
        weak var weakWebView = webView
        let emit: (String, [String: Any]) -> Void = { eventType, eventPayload in
            let args: [Any] = [requestID, eventType, eventPayload]
            guard let data = try? JSONSerialization.data(withJSONObject: args),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.__brownbear && window.__brownbear.dispatchDownload && window.__brownbear.dispatchDownload.apply(null, \(json));"
            DispatchQueue.main.async {
                if let webView = weakWebView { BBEvaluateJavaScript(webView, js, world) }
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let timeoutMs, timeoutMs > 0 { request.timeoutInterval = timeoutMs / 1000.0 }

        do {
            let (data, response) = try await Self.downloadSession.data(for: request)
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
            if error.code == NSURLErrorTimedOut {
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
}
