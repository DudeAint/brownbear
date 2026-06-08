//
//  WebExtensionMessageRouter+Permissions.swift
//  BrownBear
//
//  The permission/host gates for the host-reaching chrome.* APIs — chrome.scripting / tabs.executeScript
//  injection and chrome.cookies — split out of the router so it stays under the SwiftLint length limit.
//  Every one fails closed (CLAUDE.md §5): a zero-permission extension, or one reaching an origin it
//  wasn't granted, is denied. `store`/`host`/`cookieHost` are internal on the router, so these reach them.
//

import WebKit

extension WebExtensionMessageRouter {

    /// Gate a scripting / CSS injection on the extension actually being allowed to run in the TARGET
    /// tab's current origin. MV3 needs the "scripting" permission; MV2 executeScript/insertCSS needs
    /// "tabs" or "activeTab". Host access: "activeTab" grants the active tab only; otherwise a declared
    /// host_permission must match the tab's URL. A zero-permission extension — or one targeting an
    /// origin it wasn't granted — is denied, closing the cross-origin code-injection hole. Unknown tab
    /// / missing manifest → denied.
    func canInjectIntoTab(extensionID: String, isMV3: Bool, extTabId: Int?) async -> Bool {
        guard let host, let manifest = await store.ext(for: extensionID)?.manifest else { return false }
        let hasApiPermission = isMV3
            ? manifest.permissions.contains("scripting")
            : (manifest.permissions.contains("tabs") || manifest.permissions.contains("activeTab"))
        guard hasApiPermission else { return false }
        guard let record = host.webExtTab(extTabId: extTabId),
              let tabURL = record["url"] as? String, !tabURL.isEmpty else { return false }
        if manifest.permissions.contains("activeTab"),
           let activeId = host.webExtActionActiveTabId(), record["id"] as? Int == activeId {
            return true
        }
        // Gate on host_permissions ONLY — content_scripts.matches lets a script INJECT but confers no
        // host access in Chrome (declare-permissions). Unioning content-script matches into the gate would
        // let a content-script-only host silently read cookies / fetch cross-origin / executeScript there.
        let matcher = URLMatcher(matches: manifest.hostPermissions,
                                 includes: [], excludes: [], excludeMatches: [])
        return matcher.matches(tabURL)
    }

    // MARK: - chrome.cookies

    func routeCookies(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
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
            let scoped = (details["url"] as? String) != nil || (details["domain"] as? String)?.isEmpty == false
            if scoped {
                guard try await cookieHostAllowed(extensionID: extensionID, details: details) else {
                    throw BrownBearError.bridgeRejected("no host permission for this cookies.getAll filter")
                }
                return await host.webExtGetAllCookies(filter: details, storeId: storeId)
            }
            // Unscoped getAll({}) must NOT return every cookie — filter to the extension's host
            // permissions ONLY (a content_scripts match is not host access in Chrome; else "cookies"
            // alone exfiltrates all sessions). Fail closed.
            guard let manifest = await store.ext(for: extensionID)?.manifest else { return [] }
            let matcher = URLMatcher(matches: manifest.hostPermissions,
                                     includes: [], excludes: [], excludeMatches: [])
            let all = await host.webExtGetAllCookies(filter: details, storeId: storeId)
            return all.filter { cookie in
                guard let domain = cookie["domain"] as? String else { return false }
                let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                let scheme = ((cookie["secure"] as? Bool) ?? false) ? "https" : "http"
                return matcher.matches("\(scheme)://\(bare)\((cookie["path"] as? String) ?? "/")")
            }
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

    func hasCookiesPermission(extensionID: String) async throws -> Bool {
        guard let manifest = await store.ext(for: extensionID)?.manifest else { return false }
        return manifest.permissions.contains("cookies")
    }

    func cookieHostAllowed(extensionID: String, details: [String: Any]) async throws -> Bool {
        guard let manifest = await store.ext(for: extensionID)?.manifest else { return false }
        // Gate on host_permissions ONLY — content_scripts.matches lets a script INJECT but confers no
        // host access in Chrome (declare-permissions). Unioning content-script matches into the gate would
        // let a content-script-only host silently read cookies / fetch cross-origin / executeScript there.
        let matcher = URLMatcher(matches: manifest.hostPermissions,
                                 includes: [], excludes: [], excludeMatches: [])
        // Gate on the cookie's EFFECTIVE domain (an explicit `domain` wins over `url`) — see
        // WebExtensionCookieMapper.scopeAllowed. Closes the cross-domain cookies.set bypass.
        return WebExtensionCookieMapper.scopeAllowed(details: details) { matcher.matches($0) }
    }

    // MARK: - chrome-extension page fetch (CORS-free, host_permission-gated)

    /// Hard cap so a huge cross-origin download can't balloon the (base64) bridge payload back to the page.
    private static let maxHostFetchBytes = 16 * 1024 * 1024

    /// Proxy a host-permitted cross-origin http(s) request for an extension PAGE through URLSession — the
    /// privileged, CORS-free path Chrome gives extension pages. Fails closed: an http(s) host the
    /// extension didn't declare in host_permissions returns `{notPermitted: true}` (the page then falls
    /// back to a normal CORS fetch), so this is never an open proxy (CLAUDE.md §5). Same host-permission
    /// matcher as chrome.cookies; only http(s) is proxied (own packaged resources use the scheme handler).
    func routeHostFetch(payload: [String: Any], extensionID: String) async -> [String: Any] {
        let urlString = (payload["url"] as? String) ?? ""
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ["error": "invalid URL"]
        }
        guard let manifest = await store.ext(for: extensionID)?.manifest else { return ["notPermitted": true] }
        let matcher = URLMatcher(matches: manifest.hostPermissions,
                                 includes: [], excludes: [], excludeMatches: [])
        guard matcher.matches(urlString) else { return ["notPermitted": true] }

        var request = URLRequest(url: url)
        let method = (payload["method"] as? String)?.uppercased() ?? "GET"
        request.httpMethod = method
        request.timeoutInterval = 60
        if let headers = payload["headers"] as? [String: Any] {
            WebExtensionFetchSecurity.apply(headers: headers, to: &request)   // drops CRLF / invalid names
        }
        if let body = payload["body"] as? String, method != "GET", method != "HEAD" {
            request.httpBody = body.data(using: .utf8)
        }
        // A redirect-guarded session: a permitted host can't 30x-redirect the request onto an undeclared/
        // internal host (the gate above only sees the initial URL). Invalidate it once the request settles.
        let session = WebExtensionFetchSecurity.redirectGuardedSession(hostPatterns: manifest.hostPermissions)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return ["error": "no HTTP response"] }
            let clamped = data.count > Self.maxHostFetchBytes ? Data(data.prefix(Self.maxHostFetchBytes)) : data
            var headerMap: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headerMap[String(describing: key).lowercased()] = String(describing: value)
            }
            return [
                "ok": (200...299).contains(http.statusCode),
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "url": http.url?.absoluteString ?? urlString,
                "headers": headerMap,
                "bodyBase64": clamped.base64EncodedString()
            ]
        } catch {
            return ["error": error.localizedDescription]
        }
    }
}
