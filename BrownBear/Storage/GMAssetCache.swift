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

    /// `directory` defaults to `Caches/GMAssets`; tests inject a temporary directory so they never
    /// touch the real cache.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("GMAssets", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// The cached entry for `url`, or nil if nothing has been stored for it yet.
    func entry(for url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// Persist `entry` for `url`, replacing any prior copy.
    func store(_ entry: Entry, for url: URL) {
        guard let encoded = try? JSONEncoder().encode(entry) else { return }
        try? encoded.write(to: fileURL(for: url), options: .atomic)
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
