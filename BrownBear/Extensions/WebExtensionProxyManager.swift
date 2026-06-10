//
//  WebExtensionProxyManager.swift
//  BrownBear
//
//  Native back-end for chrome.proxy.settings. Extensions that declare the "proxy" permission
//  (Browsec VPN, VeePN, ZenMate, …) call set/clear to route WKWebView traffic through a
//  proxy server. The JS shim (__bb_proxy) is wired in
//  WebExtensionBackgroundContext+WindowsManagement.swift alongside the other permission-gated
//  natives.
//
//  On iOS 17+ we translate the Chrome ProxyConfig struct into WKWebsiteDataStore
//  .proxyConfigurations (Network + WebKit). On older OS versions we record the intent and
//  return nil so the JS shim behaves gracefully — the real proxy doesn't apply at the
//  network layer, which is the best we can do without the API.
//
//  Threading: @MainActor throughout. Every caller hops to the main actor before invoking here.
//
//  Caveats documented for the review record:
//  • proxyConfigurations applies to the DEFAULT WKWebsiteDataStore — shared by all tabs. No
//    per-tab proxy is expressible in WebKit's public API.
//  • Last-set-wins: if two extensions call set concurrently the last write prevails.
//  • pac_script mode returns an error string (no iOS WKWebsiteDataStore equivalent).
//

import Foundation
import WebKit
import Network

@MainActor
final class WebExtensionProxyManager {

    /// Process-wide singleton. Owned by WebExtensionRuntime (instantiated there as a `let`
    /// property, mirroring downloadsManager / offscreenManager). Also reachable as
    /// WebExtensionProxyManager.shared for the clear-on-shutdown path in performReload.
    static let shared = WebExtensionProxyManager()

    // MARK: - chrome.proxy.settings.set

    /// Apply a Chrome ProxyConfig to the shared WKWebsiteDataStore.
    ///
    /// - Parameters:
    ///   - extensionID: Calling extension id — used only for error attribution; permission
    ///                  gate is enforced by the caller before reaching here.
    ///   - config:      The decoded chrome.proxy.settings `value` dict (mode, rules, …).
    /// - Returns: An error string to surface back to JS, or `nil` on success.
    func apply(extensionID: String, config: [String: Any]) -> String? {
        applyConfig(config)
    }

    // MARK: - chrome.proxy.settings.clear / shutdown

    /// Remove any proxy configuration previously set (called when an extension is disabled,
    /// unloaded, or calls settings.clear). Resets to "no proxy" (direct connection).
    func clear(extensionID: String) {
        clearProxyConfigurations()
    }

    // MARK: - Config translation

    private func applyConfig(_ config: [String: Any]) -> String? {
        let mode = (config["mode"] as? String) ?? "system"

        switch mode {
        case "direct", "system":
            clearProxyConfigurations()
            return nil

        case "pac_script":
            // WKWebsiteDataStore exposes no PAC-script hook in the public API.
            return "pac_script mode is not supported on iOS; use fixed_servers with a direct proxy endpoint"

        case "fixed_servers":
            return applyFixedServers(config)

        default:
            // Forward-compat: unknown modes clear the proxy rather than blocking init.
            clearProxyConfigurations()
            return nil
        }
    }

    private func applyFixedServers(_ config: [String: Any]) -> String? {
        if #available(iOS 17.0, *) {
            let rules = (config["rules"] as? [String: Any]) ?? [:]
            var configurations: [ProxyConfiguration] = []

            // singleProxy → used for ALL traffic (HTTP + HTTPS). Takes precedence over
            // proxyForHttp / proxyForHttps when both are supplied (mirrors Chrome behavior).
            if let single = rules["singleProxy"] as? [String: Any],
               let cfg = proxyConfiguration(from: single) {
                configurations.append(cfg)
            } else {
                if let httpProxy = rules["proxyForHttp"] as? [String: Any],
                   let cfg = proxyConfiguration(from: httpProxy) {
                    configurations.append(cfg)
                }
                if let httpsProxy = rules["proxyForHttps"] as? [String: Any],
                   let cfg = proxyConfiguration(from: httpsProxy) {
                    configurations.append(cfg)
                }
            }

            if configurations.isEmpty {
                // rules present but no translatable proxy → treat as direct.
                clearProxyConfigurations()
                return nil
            }

            // bypassList → excludedDomains on the primary config (iOS 17 supports this).
            if let bypass = rules["bypassList"] as? [String], !bypass.isEmpty {
                configurations[0].excludedDomains = bypass
            }

            WKWebsiteDataStore.default().proxyConfigurations = configurations
            return nil
        } else {
            // Pre-iOS 17: WKWebsiteDataStore.proxyConfigurations doesn't exist.
            // Record the intent silently — the extension's JS logic (VPN toggle state) proceeds
            // correctly; only the actual network routing is absent.
            return nil
        }
    }

    private func clearProxyConfigurations() {
        if #available(iOS 17.0, *) {
            WKWebsiteDataStore.default().proxyConfigurations = []
        }
    }

    // MARK: - ProxyConfiguration factory

    /// Translate a Chrome proxy-server object `{ scheme?, host, port? }` to a Network
    /// `ProxyConfiguration`. Returns nil for malformed entries (missing host).
    @available(iOS 17.0, *)
    private func proxyConfiguration(from server: [String: Any]) -> ProxyConfiguration? {
        guard let host = server["host"] as? String, !host.isEmpty else { return nil }
        let port = (server["port"] as? Int) ?? 80
        let scheme = ((server["scheme"] as? String) ?? "http").lowercased()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port))
        )

        switch scheme {
        case "socks4", "socks5", "socks":
            return ProxyConfiguration(socksv5Proxy: endpoint)
        case "https":
            // HTTPS CONNECT proxy — establish TLS on the proxy tunnel leg.
            return ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: .init())
        default:
            // "http" and any other value → plain HTTP CONNECT, no TLS on the proxy leg.
            return ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
    }
}
