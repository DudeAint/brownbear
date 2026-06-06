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
            // Skip no-op writes so onChanged isn't fired for an unchanged value.
            if map[key] == value { continue }
            changes[key] = (map[key], value)
            map[key] = value
        }
        guard !changes.isEmpty else { return [:] }
        commit(map, extensionID: extensionID, area: area)
        broadcast(extensionID: extensionID, area: area, changes: changes)
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
        guard !changes.isEmpty else { return [:] }
        commit(map, extensionID: extensionID, area: area)
        broadcast(extensionID: extensionID, area: area, changes: changes)
        return changes
    }

    @discardableResult
    func clear(extensionID: String, area: Area) -> [String: (old: String?, new: String?)] {
        let existing = map(extensionID: extensionID, area: area)
        guard !existing.isEmpty else { return [:] }
        var changes: [String: (old: String?, new: String?)] = [:]
        for (key, value) in existing { changes[key] = (value, nil) }
        commit([:], extensionID: extensionID, area: area)
        broadcast(extensionID: extensionID, area: area, changes: changes)
        return changes
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
        // chrome.storage.session is in-memory only (Chrome contract): never load it from disk, so it
        // starts empty on every launch — extensions keep short-lived/sensitive state there.
        if area != .session,
           let data = defaults.data(forKey: storageKey(extensionID, area)),
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
        guard area != .session else { return }   // ephemeral — never persisted
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: storageKey(extensionID, area))
        }
    }

    /// Announce a change set so `chrome.storage.onChanged` listeners (in background workers) fire.
    /// Posting from the actor is fine — NotificationCenter is thread-safe and observers hop to main.
    private func broadcast(extensionID: String, area: Area, changes: [String: (old: String?, new: String?)]) {
        var encoded: [String: [String: String]] = [:]
        for (key, change) in changes {
            var entry: [String: String] = [:]
            if let old = change.old { entry["oldValue"] = old }
            if let new = change.new { entry["newValue"] = new }
            encoded[key] = entry
        }
        NotificationCenter.default.post(
            name: .brownBearExtensionStorageDidChange,
            object: nil,
            userInfo: ["extensionID": extensionID, "area": area.rawValue, "changes": encoded])
    }
}
