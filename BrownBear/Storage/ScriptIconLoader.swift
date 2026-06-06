//
//  ScriptIconLoader.swift
//  BrownBear
//
//  Fetches and caches a userscript's `@icon` (ScriptMetadata.iconURL) for display in the dashboard
//  rows, the install card, and menus. Icons are UNTRUSTED remote images, so the loader fails closed:
//  it fetches with no cookies in an ephemeral session, requires an image content-type, hard-caps the
//  byte size (streaming, so a hostile server can't blow memory), and never executes anything. On any
//  failure — bad scheme, wrong type, too big, decode error, missing URL — it returns nil and callers
//  render a brand fallback glyph.
//

import UIKit

actor ScriptIconLoader {

    static let shared = ScriptIconLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let maxBytes = 256 * 1024
    /// Coalesce concurrent requests for the same URL onto one fetch.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        cache.countLimit = 256
    }

    /// The cached/loaded icon for an `@icon` URL, or nil if absent or not safely loadable.
    func icon(forURLString urlString: String?) async -> UIImage? {
        guard let urlString,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "data" else { return nil }

        let key = urlString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let running = inFlight[urlString] { return await running.value }

        let session = self.session
        let maxBytes = self.maxBytes
        let task = Task<UIImage?, Never> {
            let data: Data?
            if scheme == "data" {
                // Inline data: image — decode locally with the same byte cap.
                let decoded = try? Data(contentsOf: url)
                data = (decoded?.count ?? .max) <= maxBytes ? decoded : nil
            } else {
                data = await Self.fetch(url, session: session, maxBytes: maxBytes)
            }
            guard let data, let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[urlString] = task
        let image = await task.value
        inFlight[urlString] = nil
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Stream the response, enforcing the byte cap during download (not after) so an over-large or
    /// non-image response is abandoned early.
    private static func fetch(_ url: URL, session: URLSession, maxBytes: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        if let mime = http.mimeType, !mime.lowercased().hasPrefix("image/") { return nil }
        if http.expectedContentLength > Int64(maxBytes) { return nil }   // -1 (unknown) passes; capped below
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}
