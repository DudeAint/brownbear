//
//  WebExtensionCookieMapper.swift
//  BrownBear
//
//  Pure, side-effect-free translation between Foundation's `HTTPCookie` (what `WKHTTPCookieStore`
//  hands us) and the `chrome.cookies.Cookie` JSON shape extensions expect, plus the inverse for
//  `chrome.cookies.set` (chrome `setDetails` → an `HTTPCookie`). Kept free of WebKit and any live
//  cookie jar so it is fully unit-testable — see WebExtensionCookieMapperTests.
//
//  iOS hosts a single cookie store, so `storeId` is always "0" outbound and ignored inbound.
//  `WKWebsiteDataStore.default()` backs normal browsing; `.nonPersistent()` backs private tabs.
//

import Foundation

/// Stateless mapper between `HTTPCookie` and the chrome.cookies Cookie shape. All members are static.
enum WebExtensionCookieMapper {

    /// The only cookie store id iOS exposes (Chrome's default store). Both factory stores fold into it.
    static let storeId = "0"

    // MARK: - HTTPCookie → chrome Cookie

    /// Build the chrome.cookies `Cookie` dictionary for an `HTTPCookie`.
    ///
    /// Shape: `{ name, value, domain, hostOnly, path, secure, httpOnly, sameSite, session,
    /// expirationDate?, storeId }`. `expirationDate` (seconds since the epoch, a Double like Chrome)
    /// is present only for persistent cookies; session cookies omit it and report `session: true`.
    /// `hostOnly` is true when the cookie has no leading-dot domain (it binds to the exact host).
    static func chromeCookie(from cookie: HTTPCookie) -> [String: Any] {
        // Chrome reports `domain` WITH the leading dot for a domain (non-host-only) cookie and the
        // bare host for a host-only one; `hostOnly` flips on the leading dot. HTTPCookie stores the
        // dotted form in `.domain` when the original Set-Cookie carried a Domain attribute.
        let rawDomain = cookie.domain
        let hostOnly = !rawDomain.hasPrefix(".")
        let normalizedDomain = hostOnly ? rawDomain : String(rawDomain.dropFirst())

        var result: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            // Chrome keeps the leading dot in `domain` for non-host-only cookies.
            "domain": hostOnly ? normalizedDomain : "." + normalizedDomain,
            "hostOnly": hostOnly,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "sameSite": sameSiteString(cookie.sameSitePolicy),
            "session": cookie.isSessionOnly || cookie.expiresDate == nil,
            "storeId": storeId
        ]
        // Persistent cookies carry an absolute expiry (seconds since the epoch, fractional like Chrome).
        if !cookie.isSessionOnly, let expiry = cookie.expiresDate {
            result["expirationDate"] = expiry.timeIntervalSince1970
        }
        return result
    }

    /// chrome's lowercase `sameSite` enum for an `HTTPCookieStringPolicy` (nil ⇒ "unspecified").
    static func sameSiteString(_ policy: HTTPCookieStringPolicy?) -> String {
        guard let policy else { return "unspecified" }
        switch policy {
        case .sameSiteStrict: return "strict"
        case .sameSiteLax: return "lax"
        default: return "no_restriction"   // an explicit None (cross-site) policy.
        }
    }

    /// Map a chrome `sameSite` string back to an `HTTPCookieStringPolicy`, or nil for "unspecified".
    static func sameSitePolicy(_ value: String?) -> HTTPCookieStringPolicy? {
        switch (value ?? "").lowercased() {
        case "strict": return .sameSiteStrict
        case "lax": return .sameSiteLax
        case "no_restriction": return HTTPCookieStringPolicy(rawValue: "None")
        default: return nil   // "unspecified" or unknown — let the platform default apply.
        }
    }

    // MARK: - chrome setDetails → HTTPCookie

    /// Translate a `chrome.cookies.set` details object into an `HTTPCookie`, applying chrome's rules:
    /// the domain/path are derived from `url` unless explicitly given; an explicit `domain` (or one
    /// already carrying a leading dot) makes the cookie non-host-only; `expirationDate` (seconds since
    /// the epoch) becomes a persistent cookie, its absence a session cookie. Returns nil if `url` is
    /// missing or unusable (chrome requires it). `name` defaults to "" exactly as chrome allows.
    static func cookie(fromSetDetails details: [String: Any]) -> HTTPCookie? {
        guard let urlString = details["url"] as? String,
              let url = URL(string: urlString),
              let host = url.host, !host.isEmpty else { return nil }

        let name = (details["name"] as? String) ?? ""
        let value = (details["value"] as? String) ?? ""

        // Domain: an explicit `domain` wins and is treated as a domain cookie (leading dot) so it
        // matches subdomains, mirroring chrome; otherwise the URL host (a host-only cookie).
        let explicitDomain = (details["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let domainForCookie: String
        if let explicitDomain {
            domainForCookie = explicitDomain.hasPrefix(".") ? explicitDomain : "." + explicitDomain
        } else {
            domainForCookie = host
        }

        let path = (details["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domainForCookie,
            .path: path
        ]
        // HTTPCookie keys `.secure` on PRESENCE, not value; only add it for a secure cookie.
        if (details["secure"] as? Bool) == true { properties[.secure] = "TRUE" }

        // `expirationDate` (Double seconds since epoch) ⇒ persistent; its absence ⇒ a session cookie
        // (HTTPCookie is session-only when it has no `.expires`).
        if let expiry = doubleValue(details["expirationDate"]) {
            properties[.expires] = Date(timeIntervalSince1970: expiry)
        }

        // sameSite / HttpOnly are honored on supporting OSes; harmless otherwise.
        if let policy = sameSitePolicy(details["sameSite"] as? String) {
            properties[.sameSitePolicy] = policy.rawValue
        }
        if (details["httpOnly"] as? Bool) == true {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "YES"
        }

        return HTTPCookie(properties: properties)
    }

    // MARK: - Helpers

    /// Coerce a JSON number (Double, Int, or NSNumber over the bridge) to Double.
    private static func doubleValue(_ any: Any?) -> Double? {
        if let double = any as? Double { return double }
        if let int = any as? Int { return Double(int) }
        if let number = any as? NSNumber { return number.doubleValue }
        return nil
    }
}
