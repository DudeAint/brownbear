//
//  ShieldBlockCounter.swift
//  BrownBear
//
//  The "N requests blocked" figure WKContentRuleList refuses to give us. WebKit's content-rule-list is
//  the only network-blocking primitive iOS exposes, and it cancels a blocked subresource SILENTLY — the
//  app is never notified, so BrownBear's Shields panel (and any webRequest-based extension like uBlock
//  Origin) can otherwise only ever read "0 blocked". We recover the count at the one observable point:
//  brownbear-shield-counter.js (page world) reports the hosts a page *tried* to load; this service
//  matches each against the active blocklist's host set and tallies per web view. WebKit still does the
//  actual blocking — we only COUNT attempts to known-blocked hosts, so the figure is real but a lower
//  bound (host-anchored rules only; CSS-initiated loads and path-only rules aren't counted).
//

import WebKit

@MainActor
final class ShieldBlockCounter {
    static let shared = ShieldBlockCounter()

    /// UserDefaults kill-switch; absent == on. A page-world request-API wrapper feeds this, so the count
    /// (and, via InjectionOrchestrator, its injection) can be disabled instantly if it ever misbehaves.
    static let enabledDefaultsKey = "bbShieldBlockCounter"
    // nonisolated: read from the nonisolated WKScriptMessageHandler callback as well as the MainActor
    // orchestrator. UserDefaults is thread-safe, so this needs no actor hop.
    nonisolated static var isEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: enabledDefaultsKey) == nil ? true : d.bool(forKey: enabledDefaultsKey)
    }

    /// Registrable hosts the active blocklist blocks (e.g. "doubleclick.net"). Membership is matched
    /// against a request host AND its parent domains, mirroring how `||host^` blocks every subdomain.
    private var blockedHosts: Set<String> = []
    /// web view → requests-to-blocked-hosts since its last main-frame commit. Keyed by identity; reset
    /// on navigation, so the map stays bounded by the number of live tabs.
    private var counts: [ObjectIdentifier: Int] = [:]

    private init() {}

    func setBlockedHosts(_ hosts: Set<String>) { blockedHosts = hosts }

    func reset(for webView: WKWebView) { counts[ObjectIdentifier(webView)] = 0 }

    func count(for webView: WKWebView) -> Int { counts[ObjectIdentifier(webView)] ?? 0 }

    /// Fold one page-world report (`host → attempt-count`) into the web view's tally.
    func record(hosts: [String: Int], for webView: WKWebView) {
        guard !blockedHosts.isEmpty else { return }
        var add = 0
        for (host, n) in hosts where n > 0 && Self.isBlocked(host, in: blockedHosts) { add += n }
        guard add > 0 else { return }
        counts[ObjectIdentifier(webView), default: 0] += add
    }

    /// A host matches if it OR any parent domain is in the set: `ads.tracker.com` matches a
    /// `tracker.com` entry. Stops before a bare TLD so a "com" entry (there won't be one) can't match all.
    nonisolated static func isBlocked(_ host: String, in set: Set<String>) -> Bool {
        var h = host
        while true {
            if set.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
            if !h.contains(".") { return false }   // bare TLD — don't test
        }
    }

    // MARK: - Host extraction from a compiled content-rule list

    /// Pull the blocked HOST literals out of a compiled WebKit content-rule-list JSON. Accepts only
    /// `block` rules whose url-filter reduces cleanly to a host anchor (the `^https?://([^/]+\.)?HOST[:/]`
    /// shape our converters emit and EasyList commonly uses); path/wildcard rules are skipped. Lossy by
    /// design — an undercount beats a fabricated count.
    nonisolated static func extractHosts(fromContentRuleJSON json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: Set<String> = []
        for rule in rules {
            guard let action = rule["action"] as? [String: Any],
                  (action["type"] as? String) == "block",
                  let trigger = rule["trigger"] as? [String: Any],
                  let filter = trigger["url-filter"] as? String,
                  let host = hostFromURLFilter(filter) else { continue }
            out.insert(host)
        }
        return out
    }

    /// Best-effort host literal from a content-rule url-filter regex; nil unless it's a clean host anchor.
    nonisolated static func hostFromURLFilter(_ filter: String) -> String? {
        var s = filter
        // Strip a leading anchor + scheme + optional-subdomain group (the shapes our converters emit and
        // EasyList commonly uses). Longest prefixes first so the optional-subdomain group is consumed.
        let prefixes = [
            "^https?://([^/]+\\.)?", "^https?://(?:[^/]+\\.)?",
            "://([^/]+\\.)?", "://(?:[^/]+\\.)?",
            "^https?://", "^https://", "^http://", "://"
        ]
        for p in prefixes where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        // Read the host up to the first path/port/anchor delimiter; an escaped dot "\." becomes ".".
        var host = ""
        var i = s.startIndex
        loop: while i < s.endIndex {
            let c = s[i]
            switch c {
            case "\\":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "." { host.append("."); i = s.index(after: next); continue }
                break loop
            case "a"..."z", "A"..."Z", "0"..."9", "-", ".":
                host.append(c); i = s.index(after: i)
            default:
                break loop
            }
        }
        host = host.lowercased()
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.count >= 4, host.count <= 253 else { return nil }
        return host
    }
}
