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
        // Gate on EFFECTIVE host access (declared host_permissions ∪ user-granted optional origins) —
        // NOT content_scripts.matches, which lets a script INJECT but confers no host access in Chrome
        // (unioning those would let a content-script-only host silently read cookies / fetch cross-origin).
        let matcher = URLMatcher(matches: await effectiveHostOrigins(extensionID: extensionID, manifest: manifest),
                                 includes: [], excludes: [], excludeMatches: [])
        return matcher.matches(tabURL)
    }

    /// An extension's EFFECTIVE host-permission origins: its declared `host_permissions` (always in
    /// effect) UNION the optional origins the user granted at runtime via `chrome.permissions.request`.
    /// Gating cookies / host-fetch / injection on the DECLARED set ALONE wrongly rejected an extension
    /// whose host access is OPTIONAL and granted later — Cookie-Editor declares no host_permissions and
    /// requests the current site's origin from its popup, so every `cookies.getAll` was rejected even
    /// after the user granted it. Granted origins are user-consented (the permission prompt), so honoring
    /// them is Chrome-correct and is NOT the content_scripts-widening the per-gate comments warn against.
    func effectiveHostOrigins(extensionID: String, manifest: WebExtensionManifest?) async -> [String] {
        let granted = await BrownBearServices.shared.webExtensionPermissionGrants.granted(extensionID: extensionID)
        return (manifest?.hostPermissions ?? []) + Array(granted.origins)
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
            // Unscoped getAll({}) must NOT return every cookie — filter to the extension's EFFECTIVE host
            // access (declared host_permissions ∪ user-granted optional origins; a content_scripts match is
            // not host access in Chrome; else "cookies" alone exfiltrates all sessions). Fail closed.
            guard let manifest = await store.ext(for: extensionID)?.manifest else { return [] }
            let matcher = URLMatcher(matches: await effectiveHostOrigins(extensionID: extensionID, manifest: manifest),
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
        // Effective host access (declared host_permissions ∪ user-granted optional origins). Cookie-Editor
        // declares NO host_permissions and requests the active site's origin from its popup, so gating on
        // the declared set alone rejected every cookies.getAll even after the user granted access.
        let matcher = URLMatcher(matches: await effectiveHostOrigins(extensionID: extensionID, manifest: manifest),
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
        let effectiveOrigins = await effectiveHostOrigins(extensionID: extensionID, manifest: manifest)
        let matcher = URLMatcher(matches: effectiveOrigins,
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
        let session = WebExtensionFetchSecurity.redirectGuardedSession(hostPatterns: effectiveOrigins)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                recordNetworkLog(extensionID: extensionID, method: method, url: urlString,
                                 status: 0, bytes: nil, error: "no HTTP response")
                return ["error": "no HTTP response"]
            }
            let clamped = data.count > Self.maxHostFetchBytes ? Data(data.prefix(Self.maxHostFetchBytes)) : data
            var headerMap: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headerMap[String(describing: key).lowercased()] = String(describing: value)
            }
            recordNetworkLog(extensionID: extensionID, method: method, url: urlString,
                             status: http.statusCode, bytes: data.count,
                             responseBody: String(data: data.prefix(GMNetworkService.maxLoggedResponseBytes),
                                                  encoding: .utf8),
                             error: nil)
            return [
                "ok": (200...299).contains(http.statusCode),
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "url": http.url?.absoluteString ?? urlString,
                "headers": headerMap,
                "bodyBase64": clamped.base64EncodedString()
            ]
        } catch {
            recordNetworkLog(extensionID: extensionID, method: method, url: urlString,
                             status: 0, bytes: nil, error: error.localizedDescription)
            return ["error": error.localizedDescription]
        }
    }

    /// Mirror an extension-page / service-worker `hostFetch` into the Logs → Network inspector. Fire-and-
    /// forget so it never delays the response; tagged with the extension's name as the request's source.
    func recordNetworkLog(extensionID: String, method: String, url: String,
                          status: Int, bytes: Int?, responseBody: String? = nil, error: String?) {
        let store = self.store
        Task {
            let name = await store.ext(for: extensionID)?.displayName
            await BrownBearServices.shared.networkLogStore.append(
                NetworkLogEntry(kind: .hostFetch, method: method, url: url, statusCode: status,
                                scriptName: name, responseBytes: bytes,
                                responseBody: responseBody, error: error))
        }
    }
}
