//
//  ShieldCounterHandler.swift
//  BrownBear
//
//  Receives the host→attempt-count map that brownbear-shield-counter.js posts from the PAGE world and
//  folds it into ShieldBlockCounter for the active web view. The page world is untrusted, so this
//  handler does NO privileged work — it only validates/caps the shape and forwards it to a display
//  counter. Registered in the PAGE content world (not the privileged bridge world).
//

import WebKit

final class ShieldCounterHandler: NSObject, WKScriptMessageHandler {

    static let handlerName = "brownbearShieldCounter"
    /// Hard cap on entries accepted from one message (mirrors the shim's own MAX_HOSTS) so a hostile
    /// page can't push an unbounded map across the bridge.
    private static let maxHostsPerMessage = 512

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard ShieldBlockCounter.isEnabled,
              let body = message.body as? [String: Any],
              let rawHosts = body["hosts"] as? [String: Any],
              let webView = message.webView else { return }
        var hosts: [String: Int] = [:]
        for (key, value) in rawHosts {
            if hosts.count >= Self.maxHostsPerMessage { break }
            let host = key.lowercased()
            guard host.count >= 4, host.count <= 253, host.contains(".") else { continue }
            let n: Int
            if let i = value as? Int { n = i } else if let num = value as? NSNumber { n = num.intValue } else { continue }
            guard n > 0 else { continue }
            hosts[host] = min(n, 100_000)   // clamp a single host's count so one frame can't dominate
        }
        guard !hosts.isEmpty else { return }
        Task { @MainActor in ShieldBlockCounter.shared.record(hosts: hosts, for: webView) }
    }
}
