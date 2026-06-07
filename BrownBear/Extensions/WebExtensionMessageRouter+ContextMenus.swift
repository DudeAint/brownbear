//
//  WebExtensionMessageRouter+ContextMenus.swift
//  BrownBear
//
//  chrome.contextMenus / browser.menus routing for the CONTENT/POPUP surface, split out of the primary
//  router file to keep it under the SwiftLint length limit. Reaches the router's `store` (internal) and
//  the shared @MainActor WebExtensionContextMenuStore.
//

import Foundation

extension WebExtensionMessageRouter {

    /// chrome.contextMenus.create/update/remove/removeAll. Gated on the `contextMenus` (or Firefox
    /// `menus`) API permission, then driven through the shared WebExtensionContextMenuStore. create
    /// returns { id }; the rest return NSNull. A thrown store guard surfaces as runtime.lastError.
    func routeContextMenus(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        let perms = await store.ext(for: extensionID)?.manifest?.permissions ?? []
        guard perms.contains("contextMenus") || perms.contains("menus") else {
            throw BrownBearError.bridgeRejected("the \"contextMenus\" permission is not granted")
        }
        let menuStore = BrownBearServices.shared.webExtensionContextMenuStore
        let bare = api.hasPrefix("menus.")
            ? String(api.dropFirst("menus.".count))
            : String(api.dropFirst("contextMenus.".count))
        switch bare {
        case "create":
            let id = try menuStore.create(extensionID: extensionID,
                                          properties: payload["properties"] as? [String: Any] ?? [:])
            return ["id": id]
        case "update":
            guard let id = Self.menuItemID(payload["id"]) else {
                throw BrownBearError.bridgeRejected("contextMenus.update requires an id")
            }
            try menuStore.update(extensionID: extensionID, id: id,
                                 properties: payload["properties"] as? [String: Any] ?? [:])
            return NSNull()
        case "remove":
            guard let id = Self.menuItemID(payload["id"]) else {
                throw BrownBearError.bridgeRejected("contextMenus.remove requires an id")
            }
            try menuStore.remove(extensionID: extensionID, id: id)
            return NSNull()
        case "removeAll":
            menuStore.removeAll(extensionID: extensionID)
            return NSNull()
        default:
            throw BrownBearError.bridgeRejected("unsupported contextMenus api '\(api)'")
        }
    }

    /// contextMenus item ids are strings, but a worker may pass an integer id; normalize either form.
    static func menuItemID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let int = value as? Int { return String(int) }
        return nil
    }
}
