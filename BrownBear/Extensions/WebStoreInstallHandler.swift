//
//  WebStoreInstallHandler.swift
//  BrownBear
//
//  Backs the in-page Chrome Web Store button (brownbear-webstore.js, PAGE world). The content script
//  asks for the current extension's install state and triggers add/remove; this handler runs the real
//  WebExtensionStore install/remove against Google's CRX endpoint and replies so the button can show
//  the result and flip between "Add to BrownBear" and "Remove from BrownBear".
//
//  Security: this handler performs a privileged action (installing/removing an extension), so it is
//  gated to a Chrome Web Store frame origin and a well-formed 32-char extension id. A reply handler is
//  invoked exactly once on every path. The CRX still flows through the normal validated install path
//  (manifest parsed, files sandboxed under the extension's id).
//

import WebKit

@MainActor
final class WebStoreInstallHandler: NSObject, WKScriptMessageHandlerWithReply {

    static let handlerName = "brownbearWebStore"

    private let store: WebExtensionStore

    init(store: WebExtensionStore = BrownBearServices.shared.webExtensionStore) {
        self.store = store
        super.init()
    }

    /// True for a Chrome Web Store frame — the only origin allowed to drive install/remove.
    private static func isStoreHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "chromewebstore.google.com" || host == "chrome.google.com"
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        // Read everything off WebKit's delivery thread (main), then hop to the MainActor for work.
        let host = message.frameInfo.securityOrigin.host
        guard Self.isStoreHost(host) else {
            replyHandler(nil, "not permitted from this origin")
            return
        }
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let id = body["id"] as? String,
              ChromeWebStore.isExtensionID(id) else {
            replyHandler(nil, "malformed web-store message")
            return
        }

        Task { @MainActor in
            switch action {
            case "query":
                let ext = await store.installed(forStoreID: id)
                replyHandler(["installed": ext != nil, "name": ext?.displayName ?? ""], nil)

            case "install":
                do {
                    let data = try await ChromeWebStore.downloadCRX(forInput: id)
                    let ext = try await store.install(archive: data, storeID: id)
                    NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                    replyHandler(["installed": true, "name": ext.displayName], nil)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    replyHandler(nil, message)
                }

            case "remove":
                if let ext = await store.installed(forStoreID: id) {
                    let name = ext.displayName
                    await store.remove(id: ext.id)
                    NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                    replyHandler(["installed": false, "name": name], nil)
                } else {
                    replyHandler(["installed": false, "name": ""], nil)
                }

            default:
                replyHandler(nil, "unknown action")
            }
        }
    }
}
