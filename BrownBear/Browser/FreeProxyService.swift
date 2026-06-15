//
//  FreeProxyService.swift
//  BrownBear
//
//  Fetches and parses a public free-proxy list for the Free Proxy screen. Primary source is ProxyScrape v4
//  (JSON with per-entry country + protocol, no auth); on any failure or empty result it falls back to the
//  monosans/proxy-list `proxies.json` (MIT, hourly health-checked, also carries country). The list is
//  treated as hostile input: every entry is validated (host/port) by `FreeProxy.init?`, the result is
//  deduped and capped, and the UI gates activation behind an explicit warning.
//
//  The `parseProxyScrape`/`parseMonosans` statics are pure (Data → [FreeProxy]) so the wire-format parsing
//  is unit-tested without the network — see FreeProxyServiceTests. The actor holds a short in-memory cache
//  so re-opening the screen in a session doesn't re-hit the network.
//
//  monosans' geo data is GeoLite2/MaxMind — attribution lives in THIRD_PARTY_NOTICES.md.
//

import Foundation

/// One country in the picker: its code, display name, flag, and how many proxies it has.
struct FreeProxyCountry: Equatable {
    let code: String
    let name: String
    let flag: String
    let count: Int
}

enum FreeProxyError: LocalizedError {
    case badURL
    case httpStatus(Int)
    case tooLarge
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL: return "Internal error building the request."
        case .httpStatus(let code): return "The proxy list server returned HTTP \(code)."
        case .tooLarge: return "The proxy list was unexpectedly large and was rejected."
        case .empty: return "No usable free proxies came back. Try again in a moment."
        }
    }
}

actor FreeProxyService {

    static let shared = FreeProxyService()

    /// ProxyScrape v4 — primary. JSON, per-entry country + protocol, no API key.
    static let primaryURLString =
        "https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies"
        + "&proxy_format=protocolipport&format=json"
    /// monosans/proxy-list — fallback. MIT, hourly health-checked, per-entry geolocation.
    static let fallbackURLString = "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies.json"

    /// Upstream refreshes roughly every minute; a short cache keeps re-opens snappy without hammering it.
    static let cacheTTL: TimeInterval = 12 * 60
    /// Hard cap on the number of entries shown so a hostile/huge response can't blow up the picker.
    static let maxEntries = 300
    /// Hard cap on the fetched body — the list is untrusted, so we abort the download rather than buffer a
    /// runaway response into memory. Generous enough for the full ProxyScrape / monosans lists.
    static let maxBytes = 16 * 1024 * 1024

    /// A dedicated cookieless, cacheless session so these untrusted third-party hosts can't read or set
    /// cookies in the app-wide jar or persist cache entries (matches ScriptIconLoader / ProxyManager.check).
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var cached: (fetchedAt: Date, proxies: [FreeProxy])?

    /// Cache-first load (12-min TTL). Tries ProxyScrape v4, falls back to monosans on error/empty. Throws
    /// only when BOTH sources fail. Runs entirely off the main actor.
    func load(forceRefresh: Bool = false) async throws -> [FreeProxy] {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return cached.proxies
        }
        let fresh = try await fetchFresh()
        cached = (Date(), fresh)
        return fresh
    }

    private func fetchFresh() async throws -> [FreeProxy] {
        if let primary = try? await fetch(Self.primaryURLString, parse: Self.parseProxyScrape),
           !primary.isEmpty {
            return Self.postProcess(primary)
        }
        let fallback = try await fetch(Self.fallbackURLString, parse: Self.parseMonosans)
        let processed = Self.postProcess(fallback)
        guard !processed.isEmpty else { throw FreeProxyError.empty }
        return processed
    }

    private func fetch(_ urlString: String,
                       parse: (Data) throws -> [FreeProxy]) async throws -> [FreeProxy] {
        guard let url = URL(string: urlString) else { throw FreeProxyError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Stream the body with a hard byte cap so a hostile/compromised source can't OOM the app: bail on a
        // declared length over the cap, and abort the moment the running total crosses it.
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { throw FreeProxyError.httpStatus(http.statusCode) }
            if http.expectedContentLength > Int64(Self.maxBytes) { throw FreeProxyError.tooLarge }
        }
        var data = Data()
        data.reserveCapacity(min(Self.maxBytes, 512 * 1024))
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw FreeProxyError.tooLarge }
        }
        return try parse(data)
    }

    // MARK: - Pure parsing + shaping (the unit-test seam)

    /// Parse a ProxyScrape v4 response into validated candidates (drops dead/malformed entries).
    static func parseProxyScrape(_ data: Data) throws -> [FreeProxy] {
        let decoded = try JSONDecoder().decode(ProxyScrapeResponse.self, from: data)
        return decoded.proxies.compactMap { entry in
            guard entry.alive != false, let kind = FreeProxy.kind(fromProtocol: entry.protocol) else {
                return nil
            }
            return FreeProxy(host: entry.ip, port: entry.port, kind: kind,
                             countryCode: entry.ipData?.countryCode, countryName: entry.ipData?.country)
        }
    }

    /// Parse a monosans `proxies.json` array into validated candidates.
    static func parseMonosans(_ data: Data) throws -> [FreeProxy] {
        let entries = try JSONDecoder().decode([MonosansEntry].self, from: data)
        return entries.compactMap { entry in
            guard let kind = FreeProxy.kind(fromProtocol: entry.protocol) else { return nil }
            return FreeProxy(host: entry.host, port: entry.port, kind: kind,
                             countryCode: entry.geolocation?.country?.isoCode,
                             countryName: entry.geolocation?.country?.names?.en)
        }
    }

    /// Dedupe by host:port (keeping first occurrence) and cap the result length.
    static func postProcess(_ list: [FreeProxy]) -> [FreeProxy] {
        var seen = Set<String>()
        var result: [FreeProxy] = []
        for proxy in list {
            guard seen.insert("\(proxy.host):\(proxy.port)").inserted else { continue }
            result.append(proxy)
            if result.count >= maxEntries { break }
        }
        return result
    }

    /// The country buckets for the picker, sorted by proxy count (desc) then code (asc).
    static func countries(in list: [FreeProxy]) -> [FreeProxyCountry] {
        var byCode: [String: (name: String?, count: Int)] = [:]
        for proxy in list {
            let code = proxy.groupingCode
            var entry = byCode[code] ?? (name: nil, count: 0)
            entry.count += 1
            // Prefer the first REAL country name regardless of arrival order; the bare code is only a
            // last-resort fallback applied at finalize, so a later named entry isn't locked out.
            if entry.name == nil, let name = proxy.countryName, !name.isEmpty {
                entry.name = name
            }
            byCode[code] = entry
        }
        return byCode.map { code, value in
            let name = value.name ?? (code == FreeProxy.unknownCode ? "Unknown" : code)
            return FreeProxyCountry(code: code, name: name,
                                    flag: FreeProxy.flagEmoji(code == FreeProxy.unknownCode ? nil : code),
                                    count: value.count)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    /// Filter a list to one country code; a nil/empty code means "All".
    static func filter(_ list: [FreeProxy], countryCode: String?) -> [FreeProxy] {
        guard let code = countryCode, !code.isEmpty else { return list }
        return list.filter { $0.groupingCode == code }
    }
}

// MARK: - Wire DTOs (file-scope + private; kept flat to honor the 2-level nesting rule)

private struct ProxyScrapeResponse: Decodable {
    let proxies: [ProxyScrapeEntry]
}

private struct ProxyScrapeEntry: Decodable {
    let ip: String
    let port: Int
    let `protocol`: String
    let alive: Bool?
    let ipData: ProxyScrapeIPData?
    enum CodingKeys: String, CodingKey {
        case ip, port, `protocol`, alive
        case ipData = "ip_data"
    }
}

private struct ProxyScrapeIPData: Decodable {
    let country: String?
    let countryCode: String?
}

private struct MonosansEntry: Decodable {
    let `protocol`: String
    let host: String
    let port: Int
    let geolocation: MonosansGeo?
}

private struct MonosansGeo: Decodable {
    let country: MonosansCountry?
}

private struct MonosansCountry: Decodable {
    let isoCode: String?
    let names: MonosansNames?
    enum CodingKeys: String, CodingKey {
        case isoCode = "iso_code"
        case names
    }
}

private struct MonosansNames: Decodable {
    let en: String?
}
