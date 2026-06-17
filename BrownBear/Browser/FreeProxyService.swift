//
//  FreeProxyService.swift
//  BrownBear
//
//  Fetches and parses public free-proxy lists for the Free Proxy screen. Several sources are pulled
//  CONCURRENTLY and merged for breadth — ProxyScrape v4 and monosans/proxy-list (both JSON with per-entry
//  country + protocol, hourly health-checked), proxifly/free-proxy-list (JSON, country), and TheSpeedX's
//  plain ip:port lists (volume). Each source is best-effort: one dead host can't sink the batch. The lists
//  are treated as hostile input — every entry is validated (host/port) by `FreeProxy.init?`, the merged
//  result is deduped and capped, and the UI gates activation behind an explicit warning.
//
//  A source's own "alive" flag is stale by the time the user sees it, so the picker also LIVENESS-CHECKS
//  candidates before offering them: `verify(_:onAlive:)` fans out bounded-concurrency `probe(_:)` calls
//  that fetch a tiny 204 endpoint THROUGH each proxy and stream back only the ones that actually answer
//  (with latency). That whole path is iOS 17+ (URLSession proxy configs); below it the raw list is shown.
//
//  The `parseProxyScrape`/`parseMonosans`/`parseProxifly`/`parsePlainList` statics are pure
//  (Data → [FreeProxy]) so the wire-format parsing is unit-tested without the network — see
//  FreeProxyServiceTests. The actor holds a short in-memory cache so re-opening the screen in a session
//  doesn't re-hit the network.
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
    /// monosans/proxy-list — MIT, hourly health-checked, per-entry geolocation.
    static let fallbackURLString = "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies.json"
    /// proxifly/free-proxy-list — MIT, JSON with protocol + geolocation (served from the jsDelivr CDN).
    static let proxiflyURLString = "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/all/data.min.json"
    /// TheSpeedX/PROXY-List — plain `ip:port` lists per protocol (no country). Adds volume.
    static let speedxHTTPURLString = "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt"
    static let speedxSocks5URLString = "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt"
    /// A tiny, fast 204 endpoint fetched THROUGH a candidate proxy to prove it actually works.
    static let probeURLString = "https://www.gstatic.com/generate_204"

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
        // Pull every source CONCURRENTLY and merge — more sources means more candidates, which the picker's
        // liveness check then whittles down to ones that actually answer. Each fetch is best-effort (`try?`)
        // so one slow or dead host can't sink the batch. Order matters: the country-bearing, already
        // health-checked sources come FIRST, so after dedup+cap the verifier reaches likely-live proxies
        // soonest; the bare ip:port lists (no country, less curated) fill in behind them for volume.
        async let scrape = fetch(Self.primaryURLString, parse: Self.parseProxyScrape)
        async let mono = fetch(Self.fallbackURLString, parse: Self.parseMonosans)
        async let proxifly = fetch(Self.proxiflyURLString, parse: Self.parseProxifly)
        async let speedxHTTP = fetch(Self.speedxHTTPURLString) { try Self.parsePlainList($0, proto: "http") }
        async let speedxSocks = fetch(Self.speedxSocks5URLString) { try Self.parsePlainList($0, proto: "socks5") }

        var merged: [FreeProxy] = []
        merged += (try? await scrape) ?? []
        merged += (try? await mono) ?? []
        merged += (try? await proxifly) ?? []
        merged += (try? await speedxHTTP) ?? []
        merged += (try? await speedxSocks) ?? []

        let processed = Self.postProcess(merged)
        guard !processed.isEmpty else { throw FreeProxyError.empty }
        return processed
    }

    // `nonisolated` so the `async let` fetches in `fetchFresh` run in genuine parallel rather than
    // contending on the actor — it touches only `session` (an immutable Sendable `let`, already
    // nonisolated) and statics. `parse` is `@Sendable` so it can be captured by those child tasks.
    private nonisolated func fetch(_ urlString: String,
                                   parse: @Sendable (Data) throws -> [FreeProxy]) async throws -> [FreeProxy] {
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

    /// Parse a proxifly `data.min.json` array into validated candidates. Host/port come from the explicit
    /// `ip`/`port` fields when present, else are recovered from the `proxy` URL — so a field rename upstream
    /// degrades to fewer proxies rather than a decode crash. `geolocation.country` is an ISO-2 code.
    static func parseProxifly(_ data: Data) throws -> [FreeProxy] {
        let entries = try JSONDecoder().decode([ProxiflyEntry].self, from: data)
        return entries.compactMap { entry in
            guard let proto = entry.protocol, let kind = FreeProxy.kind(fromProtocol: proto) else { return nil }
            var host = entry.ip
            var port = entry.port
            if (host == nil || port == nil), let raw = entry.proxy, let url = URL(string: raw) {
                host = host ?? url.host
                port = port ?? url.port
            }
            guard let host, let port else { return nil }
            return FreeProxy(host: host, port: port, kind: kind,
                             countryCode: entry.geolocation?.country, countryName: nil)
        }
    }

    /// Parse a plain `ip:port`-per-line list (TheSpeedX) into validated candidates of a single, known
    /// protocol — the file carries no protocol or country column. Bounded so a hostile/huge file can't run
    /// away before the dedupe+cap in `postProcess` trims it.
    static func parsePlainList(_ data: Data, proto: String) throws -> [FreeProxy] {
        guard let kind = FreeProxy.kind(fromProtocol: proto),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [FreeProxy] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = rawLine.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]) else { continue }
            if let proxy = FreeProxy(host: String(parts[0]), port: port, kind: kind,
                                     countryCode: nil, countryName: nil) {
                result.append(proxy)
            }
            if result.count >= maxEntries * 4 { break }   // generous pre-dedupe ceiling
        }
        return result
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

    // MARK: - Liveness checking (so the picker only ever offers proxies that just answered)

    /// Open a tiny 204 endpoint THROUGH `proxy` and time the round-trip. Returns the latency in
    /// milliseconds when the proxy actually relays the request, or nil if it's dead, blocked, or too slow.
    /// iOS 17+ only (URLSession proxy configs); nil below that. Each call uses its own throwaway ephemeral
    /// session so nothing leaks between probes or into the app's cookie/cache jars — these are untrusted
    /// hosts. `nonisolated` so the verifier can fan many of these out concurrently off any actor.
    nonisolated static func probe(_ proxy: FreeProxy, timeout: TimeInterval = 5) async -> Int? {
        guard #available(iOS 17.0, *),
              let config = ProxyManager.makeConfiguration(proxy.asBBProxy(label: "probe")),
              let url = URL(string: probeURLString) else { return nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.proxyConfigurations = [config]
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        sessionConfig.waitsForConnectivity = false
        sessionConfig.httpCookieStorage = nil
        sessionConfig.urlCache = nil
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let start = DispatchTime.now()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return nil
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            return Int(elapsed / 1_000_000)
        } catch {
            return nil
        }
    }

    /// Health-check `candidates` in parallel (bounded `concurrency`), invoking `onAlive(proxy, latencyMs)`
    /// for each one that answers, until `target` live proxies are found or the list is exhausted. So the
    /// picker streams in only proxies that JUST worked instead of trusting a source's stale "alive" flag.
    /// Calls nothing when proxy support is unavailable (iOS < 17). Honors task cancellation, so a view
    /// dismiss / reload stops the sweep promptly.
    nonisolated static func verify(_ candidates: [FreeProxy],
                                   target: Int = 40,
                                   concurrency: Int = 24,
                                   timeout: TimeInterval = 5,
                                   onAlive: @Sendable @escaping (FreeProxy, Int) async -> Void) async {
        guard ProxyManager.isSupported, !candidates.isEmpty else { return }
        let progress = ProbeProgress()
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let initial = min(concurrency, candidates.count)
            while next < initial {
                let proxy = candidates[next]
                next += 1
                group.addTask { await runProbe(proxy, target: target, timeout: timeout,
                                               progress: progress, onAlive: onAlive) }
            }
            // As each probe finishes, top the pool back up — keeping ~`concurrency` in flight — until we hit
            // the target or run out. Cancellation (view gone) breaks out and tears down the in-flight tasks.
            for await _ in group {
                if Task.isCancelled { break }
                if await progress.reached(target) { break }
                guard next < candidates.count else { continue }
                let proxy = candidates[next]
                next += 1
                group.addTask { await runProbe(proxy, target: target, timeout: timeout,
                                               progress: progress, onAlive: onAlive) }
            }
        }
    }

    /// One verifier slot: skip if we've already hit the target or were cancelled, otherwise probe and, if
    /// live AND still within the target, hand the result to `onAlive`.
    private nonisolated static func runProbe(_ proxy: FreeProxy, target: Int, timeout: TimeInterval,
                                             progress: ProbeProgress,
                                             onAlive: @Sendable (FreeProxy, Int) async -> Void) async {
        if Task.isCancelled { return }
        if await progress.reached(target) { return }
        guard let latencyMs = await probe(proxy, timeout: timeout) else { return }
        if await progress.record(limit: target) { await onAlive(proxy, latencyMs) }
    }

    /// `verify` as an `AsyncStream` of `(proxy, latencyMs)`, so a SwiftUI view can consume live results on
    /// the main actor (updating @State directly) without a @Sendable closure having to capture the view.
    /// The backing sweep is cancelled when the stream's consumer is torn down (view dismiss / reload).
    nonisolated static func verifiedStream(_ candidates: [FreeProxy],
                                           target: Int = 40,
                                           concurrency: Int = 24,
                                           timeout: TimeInterval = 5) -> AsyncStream<(FreeProxy, Int)> {
        AsyncStream { continuation in
            let task = Task {
                await verify(candidates, target: target, concurrency: concurrency, timeout: timeout) { proxy, ms in
                    continuation.yield((proxy, ms))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Verifier state (file-scope to honor the 2-level nesting rule)

/// Thread-safe live-proxy tally shared across the parallel verifier's probe tasks.
private actor ProbeProgress {
    private var found = 0
    /// True once we've surfaced `target` live proxies — the signal to stop scheduling more.
    func reached(_ target: Int) -> Bool { found >= target }
    /// Count one live proxy; returns true only if it's within `limit` (i.e. should be surfaced), so a probe
    /// that completes just as the target is reached doesn't push a surplus result.
    func record(limit: Int) -> Bool {
        guard found < limit else { return false }
        found += 1
        return true
    }
}

// MARK: - Wire DTOs (file-scope + private; kept flat to honor the 2-level nesting rule)

private struct ProxyScrapeResponse: Decodable {
    let proxies: [ProxyScrapeEntry]
}

private struct ProxiflyEntry: Decodable {
    let proxy: String?
    let `protocol`: String?
    let ip: String?
    let port: Int?
    let geolocation: ProxiflyGeo?
}

private struct ProxiflyGeo: Decodable {
    let country: String?
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
