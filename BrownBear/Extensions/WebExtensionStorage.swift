//
//  WebExtensionStorage.swift
//  BrownBear
//
//  Backs chrome.storage.{local,sync,session} for extensions — isolated per extension AND per area,
//  so one extension can't read another's data (and `local` ≠ `sync`). Values are stored as the
//  JSON strings the extension serialized. An actor.
//

import Foundation

actor WebExtensionStorage {

    enum Area: String { case local, sync, session, managed }

    private var caches: [String: [String: String]] = [:]   // "<extID>:<area>" → key → json
    private let defaults: UserDefaults

    init(suiteName: String = "com.brownbear.webext") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - chrome.storage operations

    /// Get values for `keys` (nil = all) in an area, returned as key → JSON-encoded value.
    func get(extensionID: String, area: Area, keys: [String]?) -> [String: String] {
        let map = map(extensionID: extensionID, area: area)
        guard let keys else { return map }
        var result: [String: String] = [:]
        for key in keys where map[key] != nil { result[key] = map[key] }
        return result
    }

    /// Set `items` (key → JSON-encoded value). Returns the changes (key → (old, new) JSON).
    @discardableResult
    func set(extensionID: String, area: Area, items: [String: String]) -> [String: (old: String?, new: String?)] {
        var map = map(extensionID: extensionID, area: area)
        var changes: [String: (old: String?, new: String?)] = [:]
        for (key, value) in items {
            changes[key] = (map[key], value)
            map[key] = value
        }
        commit(map, extensionID: extensionID, area: area)
        return changes
    }

    @discardableResult
    func remove(extensionID: String, area: Area, keys: [String]) -> [String: (old: String?, new: String?)] {
        var map = map(extensionID: extensionID, area: area)
        var changes: [String: (old: String?, new: String?)] = [:]
        for key in keys where map[key] != nil {
            changes[key] = (map[key], nil)
            map.removeValue(forKey: key)
        }
        commit(map, extensionID: extensionID, area: area)
        return changes
    }

    func clear(extensionID: String, area: Area) {
        commit([:], extensionID: extensionID, area: area)
    }

    /// Remove every area for an extension (called on uninstall).
    func clearAll(extensionID: String) {
        for area in [Area.local, .sync, .session, .managed] {
            caches[cacheKey(extensionID, area)] = [:]
            defaults.removeObject(forKey: storageKey(extensionID, area))
        }
    }

    // MARK: - Backing

    private func cacheKey(_ extensionID: String, _ area: Area) -> String { "\(extensionID):\(area.rawValue)" }
    private func storageKey(_ extensionID: String, _ area: Area) -> String { "webext.\(extensionID).\(area.rawValue)" }

    private func map(extensionID: String, area: Area) -> [String: String] {
        let key = cacheKey(extensionID, area)
        if let cached = caches[key] { return cached }
        let loaded: [String: String]
        if let data = defaults.data(forKey: storageKey(extensionID, area)),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            loaded = decoded
        } else {
            loaded = [:]
        }
        caches[key] = loaded
        return loaded
    }

    private func commit(_ map: [String: String], extensionID: String, area: Area) {
        caches[cacheKey(extensionID, area)] = map
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: storageKey(extensionID, area))
        }
    }
}
