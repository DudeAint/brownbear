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

    /// Parse a proxy string in essentially any common format, so a user can paste whatever their provider
    /// gives them and have the fields filled in automatically. Recognized shapes (scheme optional; it sets
    /// the kind, else `fallbackKind` is used):
    ///   - `scheme://login:password@host:port`, `scheme://host:port`
    ///   - `login:password@host:port` and the inverted `host:port@login:password`
    ///   - bare `host:port`
    ///   - `host:port:login:password` (the ubiquitous seller format) and the inverted
    ///     `login:password:host:port` — disambiguated by which field is a valid numeric port
    ///   - `host:port:login` (no password)
    ///   - whitespace/comma/semicolon/pipe-delimited (e.g. `host port login password`)
    ///   - IPv6 literals in `[...]`
    /// In the `@` form a password may contain `:` (split on the FIRST `:`, URL-userinfo convention).
    /// Returns nil when no `host` + valid `port` (1...65535) can be extracted.
    static func parse(_ raw: String, fallbackKind: Kind = .socks5) -> BBProxy? {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a pair of surrounding quotes a copy-paste sometimes carries.
        if rest.count >= 2, let f = rest.first, f == rest.last, f == "\"" || f == "'" {
            rest = String(rest.dropFirst().dropLast())
        }
        guard !rest.isEmpty else { return nil }

        var kind = fallbackKind
        if let schemeRange = rest.range(of: "://") {
            let scheme = rest[rest.startIndex..<schemeRange.lowerBound].lowercased()
            if let k = Kind(rawValue: scheme) {
                kind = k
            } else if scheme == "socks" || scheme == "socks5h" || scheme == "socks4" {
                kind = .socks5
            }   // an unknown scheme: keep the fallback, still parse the authority
            rest = String(rest[schemeRange.upperBound...])
        }

        // No ':' but other field separators present → normalize them to ':' ("host port user pass").
        if !rest.contains(":"), rest.contains(where: { Self.fieldSeparators.contains($0) }) {
            rest = rest.split(whereSeparator: { Self.fieldSeparators.contains($0) }).joined(separator: ":")
        }

        // "@" form: credentials on one side, host:port on the other. Pick the host:port side as the one
        // that ends in a valid port (default to the standard creds-left ordering when ambiguous).
        if let at = rest.lastIndex(of: "@") {
            let lhs = String(rest[rest.startIndex..<at])
            let rhs = String(rest[rest.index(after: at)...])
            let (credsPart, hostPart) = (endsInValidPort(lhs) && !endsInValidPort(rhs))
                ? (rhs, lhs) : (lhs, rhs)
            guard let (host, port) = splitHostPort(hostPart) else { return nil }
            let (user, pass) = splitCreds(credsPart)
            return BBProxy(kind: kind, host: host, port: port, username: user, password: pass)
        }

        // Bracketed IPv6 with no creds delimiter: "[ipv6]:port[:user[:pass]]".
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            var tail = rest[rest.index(after: close)...]
            guard tail.hasPrefix(":") else { return nil }
            tail = tail.dropFirst()
            let f = tail.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard !host.isEmpty, let port = validPort(f.first ?? "") else { return nil }
            return BBProxy(kind: kind, host: host, port: port,
                           username: f.count > 1 ? f[1] : "", password: f.count > 2 ? f[2] : "")
        }

        // Plain colon-delimited.
        let p = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch p.count {
        case 2:
            guard !p[0].isEmpty, let port = validPort(p[1]) else { return nil }
            return BBProxy(kind: kind, host: p[0], port: port)
        case 3:   // host:port:user
            guard !p[0].isEmpty, let port = validPort(p[1]) else { return nil }
            return BBProxy(kind: kind, host: p[0], port: port, username: p[2], password: "")
        case 4:   // host:port:user:pass  or  user:pass:host:port
            let p1 = validPort(p[1]), p3 = validPort(p[3])
            if p3 != nil && p1 == nil {
                return BBProxy(kind: kind, host: p[2], port: p3!, username: p[0], password: p[1])
            } else if let port = p1 {   // host:port:user:pass (also the tie-breaker when both look like ports)
                return BBProxy(kind: kind, host: p[0], port: port, username: p[2], password: p[3])
            }
            return nil
        default:
            return nil
        }
    }

    /// Field separators accepted in lieu of ':' when a pasted string has no colons.
    private static let fieldSeparators: Set<Character> = [" ", ",", ";", "|", "\t"]

    /// `s` as a port in 1...65535, or nil.
    private static func validPort(_ s: String) -> Int? {
        guard let n = Int(s), (1...65_535).contains(n) else { return nil }
        return n
    }

    /// Whether `s` ends in a valid `:port` (handles a trailing `]:port` for a bracketed IPv6 host).
    private static func endsInValidPort(_ s: String) -> Bool {
        if let close = s.lastIndex(of: "]") {
            let after = s[s.index(after: close)...]
            return after.hasPrefix(":") && validPort(String(after.dropFirst())) != nil
        }
        guard let colon = s.lastIndex(of: ":") else { return false }
        return validPort(String(s[s.index(after: colon)...])) != nil
    }

    /// Split a `host:port` / `[ipv6]:port` authority; nil if it lacks a valid trailing port.
    private static func splitHostPort(_ s: String) -> (String, Int)? {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard !host.isEmpty, after.hasPrefix(":"), let port = validPort(String(after.dropFirst())) else {
                return nil
            }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[s.startIndex..<colon])
        guard !host.isEmpty, let port = validPort(String(s[s.index(after: colon)...])) else { return nil }
        return (host, port)
    }

    /// Split `user:pass` credentials on the FIRST colon (so a `:`-bearing password survives).
    private static func splitCreds(_ s: String) -> (String, String) {
        guard let colon = s.firstIndex(of: ":") else { return (s, "") }
        return (String(s[s.startIndex..<colon]), String(s[s.index(after: colon)...]))
    }
}
