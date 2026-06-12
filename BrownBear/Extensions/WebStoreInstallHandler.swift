//
//  WebStoreInstallHandler.swift
//  BrownBear
//
//  Backs the in-page store button (brownbear-webstore.js, PAGE world) across the Chrome Web Store,
//  Microsoft Edge Add-ons, and Firefox (AMO). The content script asks for the current extension's
//  install state and triggers add/remove; this handler resolves the store + extension from the PAGE
//  URL the script sends, runs the real WebExtensionStore install/remove against that store's CRX/XPI
//  endpoint, and replies so the button can flip between "Add to BrownBear" and "Remove from BrownBear".
//
//  Security: this performs a privileged action (installing/removing an extension), so it is gated to a
//  known store frame origin AND a page URL whose host matches that frame and resolves to a real store
//  detail page (ExtensionStoreSource.detect). A reply handler is invoked exactly once on every path. The
//  package still flows through the normal validated install path (manifest parsed, files sandboxed under
//  the extension's id).
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

    /// Resolve the store source for a message: the page URL must parse to a real store detail page AND
    /// belong to the same host as the calling frame (so a store frame can only act on its own listings).
    /// `nonisolated` because it's pure and called from the non-isolated message handler.
    nonisolated private static func source(frameHost: String, urlString: String) -> ExtensionStoreSource? {
        guard let url = URL(string: urlString),
              let urlHost = url.host?.lowercased(),
              urlHost == frameHost.lowercased(),
              ExtensionStoreSource.isStoreURL(url) else {
            return nil
        }
        return ExtensionStoreSource.detect(url)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage,
                                           replyHandler: @escaping (Any?, String?) -> Void) {
        // Read everything off WebKit's delivery thread (main), then hop to the MainActor for work.
        let frameHost = message.frameInfo.securityOrigin.host
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let urlString = body["url"] as? String,
              let source = Self.source(frameHost: frameHost, urlString: urlString) else {
            replyHandler(nil, "not permitted, or not a store detail page")
            return
        }
        let storeID = source.storeID

        Task { @MainActor in
            switch action {
            case "query":
                let ext = await store.installed(forStoreID: storeID)
                replyHandler(["installed": ext != nil, "name": ext?.displayName ?? ""], nil)

            case "install":
                do {
                    let data = try await source.downloadArchive()
                    let ext = try await store.install(archive: data, storeID: storeID)
                    NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                    replyHandler(["installed": true, "name": ext.displayName], nil)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    replyHandler(nil, message)
                }

            case "remove":
                if let ext = await store.installed(forStoreID: storeID) {
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
