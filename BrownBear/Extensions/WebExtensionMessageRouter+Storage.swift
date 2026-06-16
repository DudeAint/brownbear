//
//  WebExtensionMessageRouter+Storage.swift
//  BrownBear
//
//  chrome.storage.{get,set,remove,clear} + the Firefox browser.sessions per-window/per-tab value store.
//  Split out of WebExtensionMessageRouter.route() so that method (and the router class) stay within the
//  SwiftLint size/complexity limits — route() gates on the "storage."/"sessions." api prefix and forwards
//  here. Reaches the router's internal `storage` actor.
//

import Foundation

extension WebExtensionMessageRouter {

    /// Dispatch a `storage.*` or `sessions.*` api against the extension's per-extension stores. `extensionID`
    /// is already resolved from the caller's token; the storage area defaults to `local`.
    func routeStorageAndSessions(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        let area = WebExtensionStorage.Area(rawValue: (payload["area"] as? String) ?? "local") ?? .local
        switch api {
        case "storage.get":
            let keys = payload["keys"] as? [String]   // nil = all
            return await storage.get(extensionID: extensionID, area: area, keys: keys)

        case "storage.set":
            guard let items = payload["items"] as? [String: String] else {
                throw BrownBearError.bridgeRejected("storage.set missing items")
            }
            await storage.set(extensionID: extensionID, area: area, items: items)
            return NSNull()

        case "storage.remove":
            let keys = payload["keys"] as? [String] ?? []
            await storage.remove(extensionID: extensionID, area: area, keys: keys)
            return NSNull()

        case "storage.clear":
            await storage.clear(extensionID: extensionID, area: area)
            return NSNull()

        // Firefox browser.sessions.{get,set,remove}{Window,Tab}Value — a per-extension session value store
        // kept separate from the storage.* areas (so it never pollutes storage.local). The JS shim collapses
        // every window id to one bucket (single-window iOS); a value is the JSON string it sent.
        case "sessions.getValue":
            guard let key = payload["key"] as? String else {
                throw BrownBearError.bridgeRejected("sessions.getValue missing key")
            }
            return await storage.sessionGetValue(extensionID: extensionID,
                                                  bucket: sessionBucket(payload), key: key) ?? NSNull()

        case "sessions.setValue":
            guard let key = payload["key"] as? String, let value = payload["value"] as? String else {
                throw BrownBearError.bridgeRejected("sessions.setValue missing key/value")
            }
            await storage.sessionSetValue(extensionID: extensionID, bucket: sessionBucket(payload),
                                          key: key, json: value)
            return NSNull()

        case "sessions.removeValue":
            guard let key = payload["key"] as? String else {
                throw BrownBearError.bridgeRejected("sessions.removeValue missing key")
            }
            await storage.sessionRemoveValue(extensionID: extensionID,
                                              bucket: sessionBucket(payload), key: key)
            return NSNull()

        default:
            return nil   // route() only forwards storage./sessions. apis; anything else is a no-op here
        }
    }

    /// Collapse a sessions value lookup to a single bucket id: "window:<id>" or "tab:<id>". The JS shim
    /// already normalizes every window id to "w" (iOS is single-window), so getWindowValue(M) and
    /// getWindowValue(WINDOW_ID_CURRENT) land in the SAME bucket; a tab value is keyed by its tab id.
    private func sessionBucket(_ payload: [String: Any]) -> String {
        let scope = (payload["scope"] as? String) == "tab" ? "tab" : "window"
        let id = (payload["id"] as? String) ?? "w"
        return "\(scope):\(id)"
    }
}
