//
//  ScriptMessageRouter+Assets.swift
//  BrownBear
//
//  The @require/@resource side of the userscript bridge, split out of ScriptMessageRouter so the core
//  router stays under the file-length budget. Everything here serves one goal: a library-dependent
//  userscript loads its dependencies as reliably and as fast as Violentmonkey does.
//
//   • fetchAsset / fetchAndCacheAsset — fetch a declared asset natively (bypassing page CORS), backed
//     by GMAssetCache with a conditional GET (revalidate, 304, offline fallback to the last good copy).
//   • inlinedRequireCode / inlinedResourceMap — hand getScripts the already-cached bodies so the
//     runtime runs the script WITHOUT a blocking fetch round-trip per asset at document-start.
//
//  Methods are `internal` (not `private`) because the core router file calls them across the file
//  boundary; they take only primitive types, so they never need to name the fileprivate ScriptSession.
//

import Foundation

extension ScriptMessageRouter {

    /// Fetch a script asset (@require/@resource) natively. Returns text + base64 + mime so the
    /// runtime can serve both GM_getResourceText and GM_getResourceURL (as a data: URL).
    ///
    /// Backed by `GMAssetCache`: a previously-fetched asset is revalidated with a conditional GET
    /// (ETag / Last-Modified) so an unchanged require costs a 304 instead of a full download, and a
    /// network failure falls back to the last good copy — so a library-dependent script keeps working
    /// offline instead of silently loading an empty dependency. This is the Violentmonkey behavior
    /// (fetch-once, cache, revalidate) ported to the bridge fetch path.
    func fetchAsset(_ url: URL, connects: [String]) async throws -> [String: Any] {
        let (data, mime) = try await Self.fetchAndCacheAsset(url, connects: connects)
        return Self.assetPayload(data: data, mime: mime)
    }

    /// Fetch an @require/@resource into `GMAssetCache` and return its bytes + mime. Shared by the
    /// runtime's run-time fetch and the installer's install-time prefetch (so both revalidate and
    /// fall back to cache identically). `nonisolated static` — pure, uses no actor state — so the
    /// installer can warm the cache off the main actor.
    nonisolated static func fetchAndCacheAsset(_ url: URL, connects: [String],
                                               cache: GMAssetCache = .shared,
                                               session: URLSession = .shared) async throws
        -> (data: Data, mime: String) {
        // http(s) ONLY. A @require/@resource that names file:// (or any other scheme) must never be
        // fetched: at install the prefetch would otherwise read a LOCAL FILE off disk, and at runtime
        // it is an SSRF vector. This single chokepoint protects BOTH the prefetch and the bridge fetch.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw BrownBearError.bridgeRejected("@require/@resource must be an http(s) URL")
        }
        let cached = await cache.entry(for: url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // We own the caching, so bypass URLSession's HTTP cache: this makes our conditional
        // validators reach the origin and a real 304 surface (rather than URLSession transparently
        // satisfying the request from its own store and hiding whether it changed).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        // Re-validate @connect on every redirect hop so a 3xx can't bounce the @require/@resource fetch
        // to an undeclared or internal host (SSRF). pageHost = the asset's own (declared) host, so the
        // first hop is implicitly allowed; any cross-host redirect needs an @connect grant.
        let redirectGuard = GMRedirectGuard(connects: connects, pageHost: url.host)
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            let http = response as? HTTPURLResponse
            // 304 Not Modified → the cached bytes are still current; serve them.
            if http?.statusCode == 304, let cached {
                return (cached.data, cached.mimeType)
            }
            // ONLY a real 2xx body is a valid asset. A 4xx/5xx error page, or a 3xx redirect body that
            // GMRedirectGuard blocked (completionHandler(nil) COMPLETES the task with the 3xx response —
            // it does not throw), must NOT overwrite the last-good cache nor be served as the script's
            // dependency: otherwise one transient CDN hiccup permanently poisons a working @require
            // (offline fallback + every later navigation would inject the error/redirect HTML as code).
            guard let status = http?.statusCode, (200...299).contains(status) else {
                if let cached { return (cached.data, cached.mimeType) }
                let code = http?.statusCode ?? -1
                throw BrownBearError.bridgeRejected("asset fetch returned HTTP \(code) for \(url.absoluteString)")
            }
            let mime = http?.value(forHTTPHeaderField: "Content-Type")
                ?? cached?.mimeType ?? "application/octet-stream"
            let entry = GMAssetCache.Entry(
                data: data,
                etag: http?.value(forHTTPHeaderField: "ETag"),
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                mimeType: mime)
            await cache.store(entry, for: url)
            return (data, mime)
        } catch {
            // Offline / transport failure: serve the last good copy if we have one, so a require that
            // loaded once keeps the script working. Only propagate when there is nothing to fall back on.
            if let cached {
                return (cached.data, cached.mimeType)
            }
            throw error
        }
    }

    /// Shape fetched/cached asset bytes into the bridge payload the runtime expects (text + base64 +
    /// mime), so GM_getResourceText and GM_getResourceURL (a data: URL) both resolve.
    static func assetPayload(data: Data, mime: String) -> [String: Any] {
        return [
            "text": String(data: data, encoding: .utf8) ?? "",
            "base64": data.base64EncodedString(),
            "mimeType": mime
        ]
    }

    /// @require bodies already cached on disk, keyed by their URL, so the runtime can run the script
    /// without a blocking fetch per require at document-start. Uncached URLs are omitted (the runtime
    /// fetches them the normal way, which warms the cache for next time).
    static func inlinedRequireCode(_ requires: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        for urlString in requires {
            guard let url = URL(string: urlString),
                  let entry = await GMAssetCache.shared.entry(for: url),
                  let text = String(data: entry.data, encoding: .utf8) else { continue }
            out[urlString] = text
        }
        return out
    }

    /// @resource bodies already cached on disk, keyed by resource NAME and shaped as the runtime's
    /// `{ text, url }` (url = a data: URL), so GM_getResourceText/GM_getResourceURL resolve without a
    /// fetch. Uncached resources are omitted and fetched the normal way.
    static func inlinedResourceMap(_ resources: [String: String]) async -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (name, urlString) in resources {
            guard let url = URL(string: urlString),
                  let entry = await GMAssetCache.shared.entry(for: url) else { continue }
            let text = String(data: entry.data, encoding: .utf8) ?? ""
            let dataURL = "data:" + entry.mimeType + ";base64," + entry.data.base64EncodedString()
            out[name] = ["text": text, "url": dataURL]
        }
        return out
    }
}
