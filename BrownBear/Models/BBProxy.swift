//
//  BBProxy.swift
//  BrownBear
//
//  A single browser proxy: the network identity all normal tabs route through when the proxy feature is
//  on. One active proxy at a time (no per-tab "profiles") — it's applied to the shared WKWebsiteDataStore
//  via `proxyConfigurations` (iOS 17+); see ProxyManager. This type is pure value/parse logic so the
//  "protocol://login:password@host:port" parsing is unit-tested without WebKit.
//

import Foundation

/// A proxy server BrownBear can route browsing through. `Codable` so the saved list persists; `Equatable`
/// for change detection; `Identifiable` for SwiftUI lists.
struct BBProxy: Codable, Identifiable, Equatable {

    /// The proxy protocol. HTTP/HTTPS use a CONNECT proxy; SOCKS5 a SOCKSv5 proxy (iOS 17+ ProxyConfiguration).
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case http, https, socks5
        var id: String { rawValue }
        var title: String {
            switch self {
            case .http: return "HTTP"
            case .https: return "HTTPS"
            case .socks5: return "SOCKS5"
            }
        }
        /// The scheme used in the canonical proxy URL string.
        var scheme: String { rawValue }
    }

    var id: UUID = UUID()
    /// A user-facing name ("my usa proxy"); falls back to host:port in the UI when empty.
    var label: String = ""
    var kind: Kind = .socks5
    var host: String = ""
    var port: Int = 0
    var username: String = ""
    var password: String = ""
    /// Optional rotation endpoint — opening it asks the provider to assign a new exit IP. Surfaced as the
    /// "Change IP" action; never auto-fetched.
    var changeIPURL: String = ""

    /// True once it has a host and a valid port — i.e. enough to apply.
    var isComplete: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(port) }

    var hostPort: String { "\(host):\(port)" }
    var hasCredentials: Bool { !username.isEmpty }

    /// The canonical `scheme://[user:pass@]host:port` string (credentials included only when present).
    var urlString: String {
        let auth = hasCredentials ? "\(username):\(password)@" : ""
        return "\(kind.scheme)://\(auth)\(hostPort)"
    }

    /// A name for the UI: the label, or host:port when unlabeled.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? hostPort : trimmed
    }

    /// Parse a proxy string. Accepts `scheme://login:password@host:port`, `scheme://host:port`,
    /// `login:password@host:port`, and a bare `host:port`. The scheme (if present) sets the kind; otherwise
    /// `fallbackKind` is used. Returns nil if no host:port can be extracted. IPv6 literals in `[...]` are
    /// supported. A password may itself contain `:` — the split is on the FIRST `:` of the credentials
    /// (URL-userinfo convention: everything after the first colon is the password).
    static func parse(_ raw: String, fallbackKind: Kind = .socks5) -> BBProxy? {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }

        var kind = fallbackKind
        if let schemeRange = rest.range(of: "://") {
            let scheme = rest[rest.startIndex..<schemeRange.lowerBound].lowercased()
            if let k = Kind(rawValue: scheme) {
                kind = k
            } else if scheme == "socks" {
                kind = .socks5
            }   // an unknown scheme: keep the fallback, still parse the authority
            rest = String(rest[schemeRange.upperBound...])
        }

        var username = "", password = ""
        if let at = rest.lastIndex(of: "@") {
            let creds = String(rest[rest.startIndex..<at])
            rest = String(rest[rest.index(after: at)...])
            if let colon = creds.firstIndex(of: ":") {
                username = String(creds[creds.startIndex..<colon])
                password = String(creds[creds.index(after: colon)...])
            } else {
                username = creds
            }
        }

        // host:port — handle an IPv6 literal "[::1]:8080".
        var host = "", portStr = ""
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { portStr = String(after.dropFirst()) }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[rest.startIndex..<colon])
            portStr = String(rest[rest.index(after: colon)...])
        } else {
            host = rest
        }

        guard !host.isEmpty, let port = Int(portStr), (1...65_535).contains(port) else { return nil }
        return BBProxy(label: "", kind: kind, host: host, port: port, username: username, password: password)
    }
}
