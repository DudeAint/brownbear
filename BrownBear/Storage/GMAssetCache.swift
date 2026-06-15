//
//  GMAssetCache.swift
//  BrownBear
//
//  On-disk cache for natively-fetched @require/@resource assets. Without it, every page navigation
//  re-downloaded each @require over the network, and an offline or failed fetch silently yielded an
//  EMPTY dependency — so a library-dependent userscript (jQuery, etc.) loaded slowly on every page
//  and broke entirely offline. Violentmonkey avoids this by fetching @require at install and caching
//  it; this is the BrownBear equivalent: a require that has loaded at least once keeps working fast
//  and offline, validated against the origin with a conditional GET (ETag / Last-Modified) so it
//  still picks up updates.
//
//  An actor: the @MainActor message router awaits it from page-injection paths that overlap across
//  tabs and frames.
//

import CryptoKit
import Foundation

actor GMAssetCache {

    /// Process-wide cache shared by every script injection.
    static let shared = GMAssetCache()

    /// A cached asset together with the validators needed to revalidate it cheaply.
    struct Entry: Codable, Equatable {
        let data: Data
        let etag: String?
        let lastModified: String?
        let mimeType: String
    }

    private let directory: URL
    private let fileManager = FileManager.default

    /// Soft cap on total cached bytes. A `store` that pushes the cache past this evicts least-recently-
    /// USED entries (read touches the file's mtime, so a hot asset like jQuery — read every navigation but
    /// written once — survives) down to `evictTargetBytes`. Without this the cache was unbounded: a user
    /// with many @require-heavy scripts accumulated cached bundles forever (an iPad-storage creep bug).
    private let maxBytes: Int
    /// Evict down to this (80% of the cap) rather than exactly the cap, so we don't re-scan-and-evict on
    /// every single store once the cache is full.
    private let evictTargetBytes: Int

    /// `directory` defaults to `Caches/GMAssets`; tests inject a temporary directory so they never
    /// touch the real cache. `maxBytes` is the eviction cap (default 50 MB; tests pass a tiny value).
    init(directory: URL? = nil, maxBytes: Int = 50 * 1024 * 1024) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("GMAssets", isDirectory: true)
        }
        self.maxBytes = max(1, maxBytes)
        self.evictTargetBytes = max(1, maxBytes * 4 / 5)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// The cached entry for `url`, or nil if nothing has been stored for it yet.
    func entry(for url: URL) -> Entry? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        // Mark as recently used so LRU eviction keeps assets that are read often but rarely re-written.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return decoded
    }

    /// Persist `entry` for `url`, replacing any prior copy, then evict LRU entries if over the cap.
    func store(_ entry: Entry, for url: URL) {
        guard let encoded = try? JSONEncoder().encode(entry) else { return }
        try? encoded.write(to: fileURL(for: url), options: .atomic)
        evictIfOverCap()
    }

    /// Total bytes currently on disk. Diagnostic + the eviction trigger; also unit-tested directly.
    func totalBytes() -> Int {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return urls.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
    }

    /// If the cache exceeds `maxBytes`, remove least-recently-used entries (oldest mtime first) until it's
    /// back under `evictTargetBytes`. A single entry larger than the target is kept — evicting everything
    /// else still leaves it, and the loop stops rather than spinning (it's the only thing left to serve).
    private func evictIfOverCap() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var items: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            let size = values?.fileSize ?? 0
            items.append((url, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxBytes else { return }
        items.sort { $0.mtime < $1.mtime }   // least-recently-used first
        var remaining = items.count
        for item in items {
            // Stop at the target — but NEVER evict the final survivor. A single @require larger than the
            // target (a big jQuery/three.js/pdf.js bundle) must stay cached, not be wiped by the very
            // store() that wrote it; the kept entry is the most-recently-used (last in ascending order).
            if total <= evictTargetBytes || remaining <= 1 { break }
            if (try? fileManager.removeItem(at: item.url)) != nil { total -= item.size; remaining -= 1 }
        }
    }

    /// Drop every cached asset. Wired into "Clear browsing data".
    func clear() {
        guard let names = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in names { try? fileManager.removeItem(at: url) }
    }

    /// A stable, collision-resistant filename for an asset URL (SHA-256 of its absolute string), so
    /// arbitrary URLs map to safe flat filenames without escaping concerns.
    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}
