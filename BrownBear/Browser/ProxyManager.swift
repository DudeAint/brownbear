//
//  ProxyManager.swift
//  BrownBear
//
//  The single source of truth for BrownBear's browser proxy: the saved list, which one is active, and
//  whether it's enabled. When on, the active proxy is applied to the shared WKWebsiteDataStore via
//  `proxyConfigurations` (iOS 17+), so all normal-tab traffic routes through it — one proxy at a time, no
//  per-tab profiles. Private tabs route through it too while enabled. `WebViewConfigurationFactory` calls
//  `apply(to:)` at startup and on the change notification.
//
//  iOS 16 has no per-WebView proxy API, so the whole feature is gated on iOS 17 (`isSupported`); the
//  settings UI says so and stays inert there.
//

import Foundation
import Network
import WebKit

extension Notification.Name {
    /// Posted when the active proxy / enabled state changes, so the config factory re-applies it live.
    static let brownBearProxyDidChange = Notification.Name("brownBearProxyDidChange")
}

/// The result of a "Check proxy" probe — the exit IP the proxy presents, with best-effort geo.
struct ProxyCheckResult: Equatable {
    let ip: String
    let location: String?
    let timezone: String?
}

/// The outcome of a check/rotate probe: the exit info, or a human-readable failure message. (A bespoke
/// enum rather than `Result<_, String>` because `String` isn't an `Error`.)
enum ProxyCheckOutcome {
    case success(ProxyCheckResult)
    case failure(String)
}

@MainActor
final class ProxyManager: ObservableObject {

    static let shared = ProxyManager()

    /// The user's saved proxies (the "My proxies" list).
    @Published private(set) var saved: [BBProxy] = []
    /// Which saved proxy is selected as active (nil = none).
    @Published private(set) var activeID: UUID?
    /// Whether the active proxy is actually applied to browsing. Off ⇒ direct connection, proxies untouched.
    @Published private(set) var enabled: Bool = false

    /// True only where the per-WebView proxy API exists (iOS 17+). `nonisolated` so SwiftUI view bodies and
    /// `.disabled(...)` modifiers can read it without a main-actor hop — it touches no isolated state.
    nonisolated static var isSupported: Bool { if #available(iOS 17.0, *) { return true } else { return false } }

    var active: BBProxy? { activeID.flatMap { id in saved.first { $0.id == id } } }

    private let savedKey = "bbProxySaved"
    private let activeKey = "bbProxyActiveID"
    private let enabledKey = "bbProxyEnabled"
    private let defaults = UserDefaults.standard

    private init() { load() }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: savedKey),
           let decoded = try? JSONDecoder().decode([BBProxy].self, from: data) {
            saved = decoded
        }
        if let str = defaults.string(forKey: activeKey) { activeID = UUID(uuidString: str) }
        enabled = defaults.bool(forKey: enabledKey)
        // Repair an inconsistent persisted state (e.g. the active proxy was deleted out from under us).
        if active == nil { activeID = nil; enabled = false }
    }

    private func persist() {
        defaults.set((try? JSONEncoder().encode(saved)) ?? Data(), forKey: savedKey)
        defaults.set(activeID?.uuidString, forKey: activeKey)
        defaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Mutations (each re-applies + notifies)

    /// Insert or update a proxy in the saved list (matched by id), and return the stored copy.
    @discardableResult
    func upsert(_ proxy: BBProxy) -> BBProxy {
        if let i = saved.firstIndex(where: { $0.id == proxy.id }) { saved[i] = proxy } else { saved.append(proxy) }
        persistAndApply()
        return proxy
    }

    func remove(_ proxy: BBProxy) {
        saved.removeAll { $0.id == proxy.id }
        if activeID == proxy.id { activeID = nil; enabled = false }
        persistAndApply()
    }

    /// Select the active proxy (must be in `saved`) and whether it's applied. Passing nil disables proxying.
    func setActive(_ id: UUID?, enabled on: Bool) {
        if let id, saved.contains(where: { $0.id == id }) {
            activeID = id
            enabled = on
        } else {
            activeID = nil
            enabled = false
        }
        persistAndApply()
    }

    /// Toggle whether the (already-selected) active proxy is applied.
    func setEnabled(_ on: Bool) {
        enabled = on && active != nil
        persistAndApply()
    }

    private func persistAndApply() {
        if active == nil { enabled = false }
        persist()
        NotificationCenter.default.post(name: .brownBearProxyDidChange, object: nil)
    }

    // MARK: - Apply to WebKit

    /// Apply the active proxy (or clear all proxies) to a website data store. A no-op below iOS 17, and a
    /// no-op (clears) when disabled or incomplete — so toggling off always restores a direct connection.
    func apply(to dataStore: WKWebsiteDataStore) {
        guard #available(iOS 17.0, *) else { return }
        if enabled, let proxy = active, let config = Self.makeConfiguration(proxy) {
            dataStore.proxyConfigurations = [config]
        } else {
            dataStore.proxyConfigurations = []
        }
    }

    /// Build the iOS-17 ProxyConfiguration for a proxy, or nil if it's incomplete.
    @available(iOS 17.0, *)
    static func makeConfiguration(_ proxy: BBProxy) -> ProxyConfiguration? {
        guard proxy.isComplete, let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        var config: ProxyConfiguration
        switch proxy.kind {
        case .socks5: config = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http, .https: config = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
        if proxy.hasCredentials { config.applyCredential(username: proxy.username, password: proxy.password) }
        return config
    }

    // MARK: - Check / rotate

    /// Trigger a proxy's "change IP" rotation endpoint, then re-probe the exit IP so the UI shows the new
    /// one. The rotation URL is the provider's own management link — hit DIRECTLY (not through the proxy),
    /// http(s) only — after which we wait a beat for the provider to assign the new exit IP and re-check.
    func rotateIP(_ proxy: BBProxy) async -> ProxyCheckOutcome {
        let raw = proxy.changeIPURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure("Add a valid http(s) IP-change URL first.")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: url)
        } catch {
            return .failure("Couldn't reach the IP-change URL: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // let the provider assign the new exit IP
        return await check(proxy)
    }

    /// Probe a proxy by fetching an IP-echo through it. Returns the exit IP (+ best-effort city/country and
    /// timezone) on success, or a human-readable error. Uses an ephemeral session scoped to ONLY this proxy
    /// so the check is independent of the live browsing state.
    func check(_ proxy: BBProxy) async -> ProxyCheckOutcome {
        guard #available(iOS 17.0, *) else { return .failure("Proxy requires iOS 17 or later.") }
        guard let config = Self.makeConfiguration(proxy) else { return .failure("Enter a host and port first.") }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.proxyConfigurations = [config]
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.waitsForConnectivity = false
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://ipapi.co/json/") else { return .failure("Internal error.") }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ip = (json["ip"] as? String), !ip.isEmpty else {
                return .failure("Connected, but couldn't read an IP back — the proxy may be misconfigured.")
            }
            let location = [json["city"] as? String, json["country_name"] as? String]
                .compactMap { ($0?.isEmpty == false) ? $0 : nil }.joined(separator: ", ")
            return .success(ProxyCheckResult(ip: ip, location: location.isEmpty ? nil : location,
                                             timezone: json["timezone"] as? String))
        } catch {
            return .failure("Couldn't reach the internet through this proxy: \(error.localizedDescription)")
        }
    }
}
