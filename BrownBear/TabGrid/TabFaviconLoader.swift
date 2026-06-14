//
//  TabFaviconLoader.swift
//  BrownBear
//
//  Fetches a small favicon for a host so a tab row can show the site's icon (the vertical-tabs panel
//  and any future favicon surface). Backed by an in-memory cache so reopening the switcher is instant,
//  and a bounded download size so a hostile favicon can't balloon memory. Mirrors the favicon source
//  the New Tab page / dashboard already use (Google's public s2 service), which only ever sees the bare
//  host — already public the moment the page loaded — and never a path, query, or cookie.
//

import UIKit

/// Loads + caches host favicons. Marked `@unchecked Sendable` because its only stored state is an
/// `NSCache` and an `URLSession`, both thread-safe — so the shared instance is safe to use from any
/// task. The async API returns on whatever executor the caller awaits from (the cell hops to the main
/// actor itself).
final class TabFaviconLoader: @unchecked Sendable {

    static let shared = TabFaviconLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    /// Favicons are tiny; reject anything implausibly large rather than decode it.
    private static let maxBytes = 256 * 1024

    private init() {
        cache.countLimit = 512
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    /// The cached favicon for `host`, if one has already been fetched this session. Synchronous — lets a
    /// cell show the right icon on the first frame (no flash to the placeholder) when it's a repeat view.
    func cachedFavicon(forHost host: String) -> UIImage? {
        cache.object(forKey: host.lowercased() as NSString)
    }

    /// Fetch the favicon for `host`, returning the image or nil on any failure (bad host, network error,
    /// non-2xx, over-size, undecodable). A cache hit returns immediately. Results are cached for the
    /// session.
    func favicon(forHost host: String) async -> UIImage? {
        let key = host.lowercased() as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "https://www.google.com/s2/favicons?domain=\(encoded)&sz=64") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            let okStatus = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? true
            guard okStatus, data.count <= Self.maxBytes,
                  let image = UIImage(data: data)?.withRenderingMode(.alwaysOriginal) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}
