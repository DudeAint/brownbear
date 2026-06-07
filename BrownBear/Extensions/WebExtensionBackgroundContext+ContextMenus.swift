//
//  WebExtensionBackgroundContext+ContextMenus.swift
//  BrownBear
//
//  Background-worker dispatch for chrome.contextMenus / browser.menus, mirroring the +DNRUserScripts
//  static-dispatch pattern. The worker's __bb_context_menus native hops to the main actor and calls
//  this; it re-checks the permission (defense in depth — the content/popup router checks too), drives
//  the shared @MainActor WebExtensionContextMenuStore, and returns a JSON-serializable result:
//  { id } for create, NSNull for void ops, { error } when a guard throws.
//
//  Separate file (no instance-private access) to keep WebExtensionBackgroundContext under the length
//  limit; it reaches only the public store + the @MainActor context-menu store.
//

import Foundation

extension WebExtensionBackgroundContext {

    /// Map a chrome.contextMenus method + args to the shared store on the main actor. `method` may be
    /// the bare verb ("create") or the fully-qualified api ("contextMenus.create"/"menus.create").
    @MainActor
    static func dispatchContextMenus(extensionID: String, method: String, args: [String: Any]) async -> Any {
        let services = BrownBearServices.shared
        let perms = await services.webExtensionStore.ext(for: extensionID)?.manifest?.permissions ?? []
        guard perms.contains("contextMenus") || perms.contains("menus") else {
            return ["error": "the \"contextMenus\" permission is not granted"]
        }
        let store = services.webExtensionContextMenuStore
        let bare = method.contains(".") ? String(method.split(separator: ".").last ?? "") : method
        do {
            switch bare {
            case "create":
                let id = try store.create(extensionID: extensionID,
                                          properties: args["properties"] as? [String: Any] ?? [:])
                return ["id": id]
            case "update":
                guard let id = menuItemID(args["id"]) else {
                    return ["error": "contextMenus.update requires an id"]
                }
                try store.update(extensionID: extensionID, id: id,
                                 properties: args["properties"] as? [String: Any] ?? [:])
                return NSNull()
            case "remove":
                guard let id = menuItemID(args["id"]) else {
                    return ["error": "contextMenus.remove requires an id"]
                }
                try store.remove(extensionID: extensionID, id: id)
                return NSNull()
            case "removeAll":
                store.removeAll(extensionID: extensionID)
                return NSNull()
            default:
                return ["error": "unsupported contextMenus api '\(method)'"]
            }
        } catch let error as BrownBearError {
            return ["error": error.errorDescription ?? "contextMenus error"]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Item ids are strings, but a worker may pass an integer id; normalize either form.
    private static func menuItemID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let int = value as? Int { return String(int) }
        return nil
    }
}
