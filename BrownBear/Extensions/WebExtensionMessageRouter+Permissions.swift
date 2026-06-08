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
        let matcher = URLMatcher(matches: manifest.effectiveHostPatterns,
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
            // permissions, as Chrome does (else "cookies" alone exfiltrates all sessions). Fail closed.
            guard let manifest = await store.ext(for: extensionID)?.manifest else { return [] }
            let matcher = URLMatcher(matches: manifest.effectiveHostPatterns,
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
}
