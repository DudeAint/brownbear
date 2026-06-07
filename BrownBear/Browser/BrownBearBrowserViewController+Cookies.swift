//
//  BrownBearBrowserViewController+Cookies.swift
//  BrownBear
//
//  The browser's implementation of WebExtensionCookieBridgeHost — chrome.cookies over the shared
//  WKHTTPCookieStore. iOS exposes a single cookie store ("0"); reads/writes go straight to the live
//  jar WebKit serves to navigations (the persistent default store), so a cookie an extension sets is
//  immediately visible to pages. The router has ALREADY enforced the `cookies` permission and the
//  host_permission for the target before any of these run — this file does the value-shape work and
//  the WKHTTPCookieStore I/O only. Split into its own +file so it never collides with +WebExtensions.
//
//  All cookie matching follows chrome's semantics (RFC 6265 domain/path scoping). `expirationDate`,
//  `hostOnly`, `session`, and the leading-dot domain convention are handled by WebExtensionCookieMapper.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController: WebExtensionCookieBridgeHost {

    func webExtGetCookie(url: String, name: String, storeId: String?) async -> [String: Any]? {
        guard let store = configurationFactory.httpCookieStore(forStoreId: storeId),
              let parsed = URL(string: url) else { return nil }
        // chrome.cookies.get returns the cookie matching name+url with the LONGEST path (then earliest
        // creation, which WebKit doesn't expose — longest-path is the meaningful tiebreak in practice).
        let match = (await Self.cookies(in: store))
            .filter { $0.name == name && Self.cookie($0, matchesURL: parsed) }
            .sorted { $0.path.count > $1.path.count }
            .first
        return match.map(WebExtensionCookieMapper.chromeCookie(from:))
    }

    func webExtGetAllCookies(filter: [String: Any], storeId: String?) async -> [[String: Any]] {
        guard let store = configurationFactory.httpCookieStore(forStoreId: storeId) else { return [] }
        return (await Self.cookies(in: store))
            .filter { Self.cookie($0, matchesFilter: filter) }
            .map(WebExtensionCookieMapper.chromeCookie(from:))
    }

    func webExtSetCookie(details: [String: Any], storeId: String?) async -> [String: Any]? {
        guard let store = configurationFactory.httpCookieStore(forStoreId: storeId),
              let cookie = WebExtensionCookieMapper.cookie(fromSetDetails: details) else { return nil }
        await Self.setCookie(cookie, in: store)
        // chrome echoes back the resulting cookie; re-read so the value reflects what WebKit stored.
        let stored = (await Self.cookies(in: store)).first {
            $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
        }
        return WebExtensionCookieMapper.chromeCookie(from: stored ?? cookie)
    }

    func webExtRemoveCookie(url: String, name: String, storeId: String?) async -> [String: Any]? {
        guard let store = configurationFactory.httpCookieStore(forStoreId: storeId),
              let parsed = URL(string: url) else { return nil }
        guard let target = (await Self.cookies(in: store)).first(where: {
            $0.name == name && Self.cookie($0, matchesURL: parsed)
        }) else { return nil }
        await Self.deleteCookie(target, in: store)
        // chrome.cookies.remove resolves with the removal details ({ url, name, storeId, ... }).
        return ["url": url, "name": name, "storeId": storeId ?? WebExtensionCookieMapper.storeId]
    }

    func webExtGetAllCookieStores() -> [[String: Any]] {
        // iOS exposes a single store. tabIds is empty (chrome permits that) rather than mapping every
        // open tab to "uses store 0", which would add noise without any consumer benefit.
        [["id": WebExtensionCookieMapper.storeId, "tabIds": [Int]()]]
    }

    // MARK: - WKHTTPCookieStore async wrappers (completion-handler API → async/await)

    private static func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    private static func deleteCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.delete(cookie) { continuation.resume() }
        }
    }

    // MARK: - chrome cookie matching (url scope + getAll filter)

    /// Whether `cookie` would be sent on a request to `url` — domain + path + secure-scope, per chrome.
    private static func cookie(_ cookie: HTTPCookie, matchesURL url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard domain(cookie.domain, matchesHost: host) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        guard path(cookie.path, matchesRequestPath: requestPath) else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        return true
    }

    /// Whether `candidate` satisfies a chrome.cookies.getAll filter (every present field must match).
    private static func cookie(_ candidate: HTTPCookie, matchesFilter filter: [String: Any]) -> Bool {
        let cookie = candidate
        if let name = filter["name"] as? String, cookie.name != name { return false }
        if let urlString = filter["url"] as? String {
            guard let url = URL(string: urlString), Self.cookie(cookie, matchesURL: url) else { return false }
        }
        if let wantDomain = filter["domain"] as? String {
            let cookieHost = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let want = wantDomain.hasPrefix(".") ? String(wantDomain.dropFirst()) : wantDomain
            // chrome matches the filter domain OR any subdomain of it.
            let lowerCookie = cookieHost.lowercased(), lowerWant = want.lowercased()
            if lowerCookie != lowerWant && !lowerCookie.hasSuffix("." + lowerWant) { return false }
        }
        if let path = filter["path"] as? String, cookie.path != path { return false }
        if let secure = filter["secure"] as? Bool, cookie.isSecure != secure { return false }
        if let session = filter["session"] as? Bool {
            let isSession = cookie.isSessionOnly || cookie.expiresDate == nil
            if isSession != session { return false }
        }
        return true
    }

    /// Cookie-domain match: host-equal, or the request host is a subdomain of a domain cookie. WebKit
    /// stores a domain cookie with a leading dot; a host-only cookie keeps the bare host.
    private static func domain(_ cookieDomain: String, matchesHost host: String) -> Bool {
        let isDomainCookie = cookieDomain.hasPrefix(".")
        let bare = (isDomainCookie ? String(cookieDomain.dropFirst()) : cookieDomain).lowercased()
        if bare == host { return true }
        return isDomainCookie && host.hasSuffix("." + bare)
    }

    /// Cookie-path match (RFC 6265 §5.1.4): equal, a prefix ending in "/", or a prefix at a "/" boundary.
    private static func path(_ cookiePath: String, matchesRequestPath requestPath: String) -> Bool {
        if cookiePath == requestPath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        let index = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return requestPath[index] == "/"
    }
}
