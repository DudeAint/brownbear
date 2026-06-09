//
//  HistoryStore.swift
//  BrownBear
//
//  Durable browsing history, persisted as JSON. An actor because navigation recording (the browser
//  controller, on every didFinish) and the readers (History screen, omnibox suggestions, NTP top
//  sites) all touch it. Recording is high-frequency, so persistence is debounced (LogStore pattern)
//  rather than written synchronously on every visit. One entry per normalized URL; revisits bump
//  the count. Private tabs never record here — the browser controller simply doesn't call `record`.
//

import Foundation

actor HistoryStore {

    private var entries: [HistoryEntry] = []
    private var didLoad = false
    private var flushTask: Task<Void, Never>?
    private let fileURL: URL

    /// Hard cap; when exceeded we prune the lowest-frecency entries so the file can't grow forever.
    private let maxEntries = 4_000

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/history.json")
        }
    }

    // MARK: - Recording

    /// Record a visit to `url`. New URLs are inserted; revisits bump `visitCount`/`lastVisit` and
    /// adopt a newer non-empty title. Caller is responsible for filtering out about:blank, non-http
    /// schemes, and private-tab navigations before calling.
    func record(url: URL, title: String?) {
        loadIfNeeded()
        let key = Self.key(for: url)
        let cleanTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { Self.key(for: $0.url) == key }) {
            entries[index].visitCount += 1
            entries[index].lastVisit = Date()
            entries[index].url = url
            if !cleanTitle.isEmpty { entries[index].title = cleanTitle }
        } else {
            entries.append(HistoryEntry(url: url, title: cleanTitle))
        }
        scheduleFlush()
    }

    /// Update the title of the most recent matching entry — used when a page's <title> resolves
    /// after the initial didFinish (some SPAs set it late).
    func updateTitle(_ title: String, for url: URL) {
        loadIfNeeded()
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let key = Self.key(for: url)
        guard let index = entries.firstIndex(where: { Self.key(for: $0.url) == key }) else { return }
        guard entries[index].title != clean else { return }
        entries[index].title = clean
        scheduleFlush()
    }

    // MARK: - Reads

    /// Every entry, most-recently-visited first (for the History screen).
    func all() -> [HistoryEntry] {
        loadIfNeeded()
        return entries.sorted { $0.lastVisit > $1.lastVisit }
    }

    /// The N most recently visited entries.
    func recent(limit: Int) -> [HistoryEntry] {
        Array(all().prefix(max(0, limit)))
    }

    /// Frecency-ranked entries, best first — the basis for NTP top sites.
    func topSites(limit: Int) -> [HistoryEntry] {
        loadIfNeeded()
        let now = Date()
        return entries
            .sorted { $0.frecency(now: now) > $1.frecency(now: now) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Substring search over title + URL, frecency-ranked. Backs both the History screen search
    /// field and the omnibox suggestion list.
    func search(_ query: String, limit: Int) -> [HistoryEntry] {
        loadIfNeeded()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return recent(limit: limit) }
        let now = Date()
        return entries
            .filter { $0.title.lowercased().contains(needle)
                || $0.url.absoluteString.lowercased().contains(needle) }
            .sorted { lhs, rhs in
                // Prefer matches that begin at the host (a user typing "git" wants github.com,
                // not a page that merely mentions "git" deep in its path), then by frecency.
                let lp = Self.matchPriority(lhs, needle: needle)
                let rp = Self.matchPriority(rhs, needle: needle)
                if lp != rp { return lp < rp }
                return lhs.frecency(now: now) > rhs.frecency(now: now)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// The single best inline-completion candidate for a typed prefix, if any host begins with it.
    /// Returns the entry whose registrable host starts with `prefix` and has the highest frecency.
    func bestCompletion(for prefix: String) -> HistoryEntry? {
        loadIfNeeded()
        let typed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.count >= 2, !typed.contains(" ") else { return nil }
        let now = Date()
        return entries
            .filter { entry in
                let host = entry.displayHost.lowercased()
                return host.hasPrefix(typed) || ("www." + host).hasPrefix(typed)
            }
            .max { $0.frecency(now: now) < $1.frecency(now: now) }
    }

    // MARK: - Mutations

    func remove(id: UUID) {
        loadIfNeeded()
        entries.removeAll { $0.id == id }
        scheduleFlush()
    }

    func remove(url: URL) {
        loadIfNeeded()
        let key = Self.key(for: url)
        entries.removeAll { Self.key(for: $0.url) == key }
        scheduleFlush()
    }

    /// Remove every entry whose lastVisit is on or after `date` — backs "Clear last hour/today".
    func removeEntries(since date: Date) {
        loadIfNeeded()
        entries.removeAll { $0.lastVisit >= date }
        scheduleFlush()
    }

    /// Remove every entry whose lastVisit falls within `[start, end]` — backs chrome.history.deleteRange.
    /// A precise range (not "everything since X") so an extension's deleteRange can't over-delete.
    func removeEntries(from start: Date, to end: Date) {
        loadIfNeeded()
        entries.removeAll { $0.lastVisit >= start && $0.lastVisit <= end }
        scheduleFlush()
    }

    /// Wipe all history. Cancels any pending debounced write and persists the empty state at once,
    /// so a "Clear browsing data" can't be undone by a late flush of stale entries.
    func clear() {
        loadIfNeeded()
        entries.removeAll()
        flushTask?.cancel()
        flushTask = nil
        persist()
    }

    /// Persist immediately, cancelling any pending debounce. Call on app backgrounding so a jetsam
    /// kill can't lose the last visits that the debounce hadn't flushed yet.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        persist()
    }

    // MARK: - Ranking helpers

    /// Lower is better. 0 = the needle starts the host, 1 = host contains it, 2 = only title/path.
    private static func matchPriority(_ entry: HistoryEntry, needle: String) -> Int {
        let host = entry.displayHost.lowercased()
        if host.hasPrefix(needle) { return 0 }
        if host.contains(needle) { return 1 }
        return 2
    }

    // MARK: - Identity

    /// Normalize a URL for identity, matching BookmarkStore: lowercase only scheme + host (path and
    /// query are case-sensitive per RFC 3986) and strip a single trailing path slash so `/page` and
    /// `/page/` collapse to one entry. Fragments are dropped — `#section` is the same document.
    private static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? url.absoluteString
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.brownBear.decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    /// Coalesce bursts of visits into a single write ~1.5s after the last record (LogStore pattern).
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.performFlush()
        }
    }

    private func performFlush() {
        flushTask = nil
        persist()
    }

    private func persist() {
        // Enforce the cap before writing: drop the lowest-frecency entries.
        if entries.count > maxEntries {
            let now = Date()
            entries = entries
                .sorted { $0.frecency(now: now) > $1.frecency(now: now) }
                .prefix(maxEntries)
                .map { $0 }
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort; the in-memory list stays authoritative for the session.
        }
    }
}
