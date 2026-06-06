//
//  BookmarkStore.swift
//  BrownBear
//
//  Durable bookmark list, persisted as JSON. An actor because the browser chrome (add/remove/toggle)
//  and the bookmarks UI (read) both touch it. Mirrors the ScriptStore/LogStore pattern. Bookmarks are
//  user-initiated and low-frequency, so it persists synchronously on each mutation.
//

import Foundation

actor BookmarkStore {

    private var bookmarks: [Bookmark] = []
    private var didLoad = false
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/bookmarks.json")
        }
    }

    // MARK: - Reads

    /// All bookmarks, newest first.
    func all() -> [Bookmark] {
        loadIfNeeded()
        return bookmarks.sorted { $0.createdAt > $1.createdAt }
    }

    /// Whether the exact URL is already bookmarked.
    func contains(url: URL) -> Bool {
        loadIfNeeded()
        let key = Self.key(for: url)
        return bookmarks.contains { Self.key(for: $0.url) == key }
    }

    // MARK: - Mutations

    /// Add a bookmark, de-duplicating by URL (returns the existing one if already present).
    @discardableResult
    func add(title: String, url: URL) -> Bookmark {
        loadIfNeeded()
        let key = Self.key(for: url)
        if let existing = bookmarks.first(where: { Self.key(for: $0.url) == key }) {
            return existing
        }
        let bookmark = Bookmark(title: title, url: url)
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    func remove(id: UUID) {
        loadIfNeeded()
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func remove(url: URL) {
        loadIfNeeded()
        let key = Self.key(for: url)
        bookmarks.removeAll { Self.key(for: $0.url) == key }
        persist()
    }

    /// Add the URL if absent, remove it if present. Returns whether it is bookmarked afterwards.
    @discardableResult
    func toggle(title: String, url: URL) -> Bool {
        if contains(url: url) {
            remove(url: url)
            return false
        }
        add(title: title, url: url)
        return true
    }

    // MARK: - Persistence

    /// Normalize a URL for identity comparison. Per RFC 3986 only scheme and host are
    /// case-insensitive — path/query/fragment are case-sensitive (real servers distinguish
    /// `/Octocat` from `/octocat`), so lowercase ONLY scheme + host and strip a single trailing
    /// path slash (so `/page` and `/page/`, and a bare host with/without `/`, match).
    private static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? url.absoluteString
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.brownBear.decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(bookmarks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort; the in-memory list stays authoritative for the session.
        }
    }
}
