//
//  ReadingListStore.swift
//  BrownBear
//
//  Durable "read later" list, persisted as JSON. An actor because the browser chrome (add) and the
//  Reading List UI (read/mark/delete) both touch it. Mirrors BookmarkStore. Low-frequency, user-driven,
//  so it persists synchronously on each mutation.
//

import Foundation

actor ReadingListStore {

    private var items: [ReadingListItem] = []
    private var didLoad = false
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/reading-list.json")
        }
    }

    // MARK: - Reads

    /// All items, newest first.
    func all() -> [ReadingListItem] {
        loadIfNeeded()
        return items.sorted { $0.addedAt > $1.addedAt }
    }

    /// Whether the exact URL is already saved.
    func contains(url: URL) -> Bool {
        loadIfNeeded()
        let key = Self.key(for: url)
        return items.contains { Self.key(for: $0.url) == key }
    }

    /// Count of unread items, for a badge/label.
    func unreadCount() -> Int {
        loadIfNeeded()
        return items.filter { !$0.isRead }.count
    }

    // MARK: - Mutations

    /// Add an item, de-duplicating by URL (returns the existing one if already present).
    @discardableResult
    func add(title: String, url: URL) -> ReadingListItem {
        loadIfNeeded()
        let key = Self.key(for: url)
        if let existing = items.first(where: { Self.key(for: $0.url) == key }) {
            return existing
        }
        let item = ReadingListItem(title: title, url: url)
        items.append(item)
        persist()
        return item
    }

    func remove(id: UUID) {
        loadIfNeeded()
        items.removeAll { $0.id == id }
        persist()
    }

    /// Mark an item read/unread (read when you open it; togglable from the list).
    func setRead(id: UUID, _ isRead: Bool) {
        loadIfNeeded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead = isRead
        persist()
    }

    /// Mark the item with this URL read, if present (used when the page is opened from elsewhere).
    func markRead(url: URL) {
        loadIfNeeded()
        let key = Self.key(for: url)
        guard let index = items.firstIndex(where: { Self.key(for: $0.url) == key }) else { return }
        items[index].isRead = true
        persist()
    }

    // MARK: - Persistence

    /// Normalize a URL for identity comparison (scheme + host lowercased, single trailing slash stripped),
    /// matching BookmarkStore so the two stores agree on what "the same page" means.
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
              let decoded = try? JSONDecoder.brownBear.decode([ReadingListItem].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort; the in-memory list stays authoritative for the session.
        }
    }
}
