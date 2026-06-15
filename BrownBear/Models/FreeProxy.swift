//
//  FreeProxy.swift
//  BrownBear
//
//  One entry from a public free-proxy list (ProxyScrape v4 / monosans), normalized into the fields the
//  Free Proxy screen needs: host, port, kind, and best-effort country. A FreeProxy is a *candidate* the
//  user can activate; doing so promotes it to a real `BBProxy` in ProxyManager. Pure value/normalization
//  logic (no networking) so the list parsing is unit-tested without URLSession — see FreeProxyService.
//
//  ⚠️ Free public proxies are operated by unknown third parties and must be treated as hostile; the Free
//  Proxy UI carries the security warning and an explicit-confirm gate before activation.
//

import Foundation

/// A normalized free-proxy candidate. `Equatable`/`Hashable` for dedupe/tests, `Identifiable` (by host:port,
/// which `postProcess` dedupes on) for SwiftUI lists. Not persisted itself — the user's chosen one is
/// persisted as a `BBProxy` via `asBBProxy`.
struct FreeProxy: Equatable, Hashable, Identifiable {

    let host: String
    let port: Int
    let kind: BBProxy.Kind
    /// ISO-3166 alpha-2 (e.g. "DE"), or nil when the source didn't label it.
    let countryCode: String?
    /// Human-readable country name (e.g. "Germany"), or nil.
    let countryName: String?

    var id: String { "\(host):\(port)" }
    var hostPort: String { "\(host):\(port)" }

    /// Build a validated FreeProxy, or nil if the host/port are unusable (untrusted-input rule: a free list
    /// is hostile, so a malformed or out-of-range entry is dropped, never shown or activated).
    init?(host rawHost: String, port: Int, kind: BBProxy.Kind, countryCode: String?, countryName: String?) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FreeProxy.isPlausibleHost(host), (1...65_535).contains(port) else { return nil }
        self.host = host
        self.port = port
        self.kind = kind
        self.countryCode = countryCode?.uppercased()
        self.countryName = countryName
    }

    /// The country code for grouping, or a sentinel for "unknown" so those sort into one bucket.
    var groupingCode: String {
        if let code = countryCode, !code.isEmpty { return code }
        return FreeProxy.unknownCode
    }

    /// A label for the picker: "Germany (DE)", the bare code, or "Unknown".
    var countryLabel: String {
        if let name = countryName, !name.isEmpty {
            return countryCode.map { "\(name) (\($0))" } ?? name
        }
        return countryCode ?? "Unknown"
    }

    /// The regional-indicator flag emoji for the country code, or a globe when unknown.
    var flag: String { FreeProxy.flagEmoji(countryCode) }

    /// Promote this candidate to a real proxy for ProxyManager. No credentials (free proxies are open).
    func asBBProxy(label: String) -> BBProxy {
        BBProxy(label: label, kind: kind, host: host, port: port)
    }

    // MARK: - Helpers (static so the parsers/tests can reuse them)

    static let unknownCode = "ZZ"

    /// Map a wire protocol string to one of our kinds. socks4/socks5 both map to .socks5 (BrownBear has no
    /// distinct socks4), http/https map straight across; anything else is nil (the entry is dropped).
    static func kind(fromProtocol proto: String) -> BBProxy.Kind? {
        switch proto.lowercased() {
        case "http": return .http
        case "https": return .https
        case "socks5", "socks4", "socks5h": return .socks5
        default: return nil
        }
    }

    /// A cheap sanity check that `host` is a bare host/IP and not a URL, empty, or whitespace-bearing — it's
    /// about to be handed to a network stack, so reject anything that isn't a plain authority host.
    static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let bad = CharacterSet(charactersIn: " /\\@?#")
        guard host.rangeOfCharacter(from: bad.union(.whitespacesAndNewlines)) == nil else { return false }
        guard host.contains(".") || host.contains(":") else { return false }   // dotted host or IPv6 literal
        return true
    }

    /// Turn an ISO-3166 alpha-2 code into its flag emoji (regional indicators); 🌐 for unknown/invalid.
    static func flagEmoji(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "🌐" }
        let upper = code.uppercased()
        var scalars = String.UnicodeScalarView()
        for char in upper.unicodeScalars {
            guard ("A"..."Z").contains(char), let scalar = Unicode.Scalar(0x1F1E6 + (char.value - 0x41)) else {
                return "🌐"
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
