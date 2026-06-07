//
//  ConnectGrantPrompt.swift
//  BrownBear
//
//  The ScriptCat-style permission prompt shown when a userscript's GM_xmlhttpRequest targets a host
//  that is NOT in its `@connect` allowlist and hasn't been granted before. Allow persists an
//  always-allow grant for that script (ConnectGrantStore); Block denies. Presented on the topmost
//  view controller (not the browser controller) so it can be raised from the sandbox layer.
//

import UIKit

enum ConnectGrantPrompt {

    /// Ask the user whether `scriptName` may connect to `host`. Returns true to allow. If no view
    /// controller is available to present on, fails closed (returns false) — never silently allow.
    @MainActor
    static func request(scriptName: String, host: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
                  window.rootViewController != nil else {
                continuation.resume(returning: false)
                return
            }

            let title = "Allow connection?"
            let message = "“\(scriptName)” wants to connect to \(host), which isn't in its @connect list."
                + "\n\nAllow remembers this host for this script. Block denies it."
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

            var settled = false
            func finish(_ allowed: Bool) {
                guard !settled else { return }
                settled = true
                continuation.resume(returning: allowed)
            }
            alert.addAction(UIAlertAction(title: "Block", style: .cancel) { _ in finish(false) })
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in finish(true) })

            TopViewControllerPresenter.present(alert)
        }
    }
}
