//
//  ContentBlocklistUpdater.swift
//  BrownBear
//
//  Keeps BrownBear's built-in content-blocking list comprehensive and fresh, the way uBlock Origin /
//  Brave do: it fetches several maintained filter lists from the network, converts them to WebKit
//  content-rule-list JSON, merges + dedupes + caps them, and caches the result to disk. The
//  WebExtensionContentBlocker compiles the cached merged list (preferring it over the small bundled
//  starter list, which remains the offline / first-launch fallback). Lists are re-fetched on a cadence.
//
//  Sources (runtime-fetched + attributed, like Brave/uBlock — not bundled in the binary):
//    • EasyList and EasyPrivacy — published as Safari/WebKit content-blocker JSON by Adblock Plus
//      (CC BY-SA 3.0). Used directly.
//    • Peter Lowe's ad/tracking server list — a plain domain list, converted here to third-party
//      network-block rules.
//  Each source is fetched independently and a failure is skipped (the rest still apply), so a dead URL
//  never takes blocking down; if every source fails, the bundled list still serves.
//
//  Threading: @MainActor (the content blocker it feeds is @MainActor). The actual fetches are async
//  URLSession calls; conversion/merge is pure value work done off the awaited results.
//

import Foundation

extension Notification.Name {
    /// Posted (main thread) after the merged blocklist cache is refreshed, so the content blocker can
    /// recompile with the newer, larger list.
    static let brownBearBlocklistDidUpdate = Notification.Name("brownBearBlocklistDidUpdate")
}

@MainActor
final class ContentBlocklistUpdater {

    static let shared = ContentBlocklistUpdater()

    /// A maintained filter list to fetch.
    struct Source {
        let name: String
        let url: URL
        let kind: Kind
        enum Kind {
            case contentBlockerJSON   // already WebKit content-rule-list JSON
            case domainList           // plain text / hosts file → converted to third-party block rules
        }
    }

    /// uBlock-Origin-style default set. Order is priority: earlier sources win the rule budget.
    private static let sources: [Source] = [
        ("EasyPrivacy", "https://easylist-downloads.adblockplus.org/easyprivacy_content_blocker.json", Source.Kind.contentBlockerJSON),
        ("EasyList", "https://easylist-downloads.adblockplus.org/easylist_content_blocker.json", Source.Kind.contentBlockerJSON),
        ("Peter Lowe's List", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=plain&showintro=0&mimetype=plaintext", Source.Kind.domainList)
    ].compactMap { name, string, kind in
        URL(string: string).map { Source(name: name, url: $0, kind: kind) }
    }

    /// WebKit compiles large lists slowly; cap the merged set well under the iOS-16.4 ceiling so a
    /// refresh stays fast and a runaway source can't bloat the cache.
    private static let maxRules = 50_000
    /// Re-fetch when the cache is older than this.
    private static let refreshInterval: TimeInterval = 3 * 24 * 3600   // 3 days
    private static let perSourceByteCap = 8 * 1024 * 1024              // 8 MiB per fetched list

    private let cacheURL: URL
    private let stampURL: URL
    private var isUpdating = false

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("BrownBear", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("blocklist-merged.json")
        self.stampURL = dir.appendingPathComponent("blocklist-merged.stamp")
    }

    /// The cached merged content-rule-list JSON, or nil if no successful update has happened yet (then
    /// the content blocker uses the bundled starter list). Read synchronously by the content blocker.
    var cachedMergedJSON: String? {
        guard let data = try? Data(contentsOf: cacheURL),
              let json = String(data: data, encoding: .utf8), !json.isEmpty, json != "[]" else { return nil }
        return json
    }

    /// The merged-cache file URL, recomputed WITHOUT touching the @MainActor singleton, so the content
    /// blocker can read the (multi-MB) cache off the main thread. Mirrors `init()`'s path exactly.
    nonisolated static func cacheFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BrownBear", isDirectory: true)
                   .appendingPathComponent("blocklist-merged.json")
    }

    /// Read the cached merged list off the main actor (a synchronous read of this multi-MB file on the
    /// main thread is part of the cold-start freeze). Nil when absent/empty — same contract as
    /// `cachedMergedJSON`, just callable from a background task.
    nonisolated static func loadCachedMergedJSON() -> String? {
        guard let data = try? Data(contentsOf: cacheFileURL()),
              let json = String(data: data, encoding: .utf8), !json.isEmpty, json != "[]" else { return nil }
        return json
    }

    /// Whether a non-trivial merged cache exists, checked by file SIZE rather than by reading the whole
    /// multi-MB file — so the launch-time staleness check doesn't block the main thread on a big read.
    /// (">2" rejects an empty file and a bare "[]".)
    nonisolated static func cachedListIsPresent() -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: cacheFileURL().path))?[.size] as? Int
        else { return false }
        return size > 2
    }

    /// Kick off a refresh if the cache is missing or stale. Fire-and-forget; safe to call on launch.
    func updateIfStale(now: Date = Date()) {
        if let stampData = try? Data(contentsOf: stampURL),
           let stampString = String(data: stampData, encoding: .utf8),
           let epoch = TimeInterval(stampString.trimmingCharacters(in: .whitespacesAndNewlines)),
           now.timeIntervalSince1970 - epoch < Self.refreshInterval,
           Self.cachedListIsPresent() {   // cheap size check, not a multi-MB read on the main thread
            return   // fresh enough
        }
        Task { await update(now: now) }
    }

    /// Fetch every source, convert + merge + cap, and atomically replace the cache. Posts
    /// `.brownBearBlocklistDidUpdate` on success so the content blocker recompiles.
    func update(now: Date = Date()) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        var rules: [[String: Any]] = []
        var seen = Set<String>()   // dedupe by a stable signature
        for source in Self.sources {
            guard rules.count < Self.maxRules else { break }
            guard let fetched = await fetch(source) else { continue }
            let converted = Self.rules(from: fetched, kind: source.kind)
            for rule in converted {
                guard rules.count < Self.maxRules else { break }
                let signature = Self.signature(of: rule)
                if seen.insert(signature).inserted { rules.append(rule) }
            }
        }
        guard !rules.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return   // nothing fetched — keep the existing cache / bundled fallback
        }
        try? json.write(to: cacheURL, atomically: true, encoding: .utf8)
        try? String(now.timeIntervalSince1970).write(to: stampURL, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .brownBearBlocklistDidUpdate, object: nil)
    }

    // MARK: - Fetch

    private func fetch(_ source: Source) async -> Data? {
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count <= Self.perSourceByteCap else {
            return nil
        }
        return data
    }

    // MARK: - Conversion (pure)

    private static func rules(from data: Data, kind: Source.Kind) -> [[String: Any]] {
        switch kind {
        case .contentBlockerJSON:
            return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        case .domainList:
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return domainRules(from: text)
        }
    }

    /// Parse a plain-text / hosts-format domain list and convert each domain to a third-party
    /// network-block rule. Skips comments and non-domain lines; maps `0.0.0.0 host` / `127.0.0.1 host`.
    /// `internal` for table-driven tests.
    static func domainRules(from text: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
            // hosts format: "0.0.0.0 domain.com" / "127.0.0.1 domain.com" → take the last field.
            if line.hasPrefix("0.0.0.0") || line.hasPrefix("127.0.0.1") || line.hasPrefix("::1") {
                line = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? ""
            }
            // Strip an inline comment.
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            let domain = line.lowercased()
            guard isPlausibleDomain(domain), seen.insert(domain).inserted else { continue }
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            out.append([
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]],
                "action": ["type": "block"]
            ])
        }
        return out
    }

    /// A conservative domain sanity check so junk lines don't become rules.
    private static func isPlausibleDomain(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 253, s.contains("."), !s.contains(" "), !s.contains("/") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A stable signature for dedupe — the url-filter (+ action type) identifies a rule across sources.
    private static func signature(of rule: [String: Any]) -> String {
        let filter = (rule["trigger"] as? [String: Any])?["url-filter"] as? String ?? UUID().uuidString
        let action = (rule["action"] as? [String: Any])?["type"] as? String ?? ""
        let selector = (rule["action"] as? [String: Any])?["selector"] as? String ?? ""
        return "\(action)|\(filter)|\(selector)"
    }
}
