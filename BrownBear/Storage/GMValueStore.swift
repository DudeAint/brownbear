//
//  GMValueStore.swift
//  BrownBear
//
//  Backing store for GM_setValue/GM_getValue. Each script gets an isolated namespace keyed by
//  its UUID, so script A can never read script B's values (CLAUDE.md §5.3). Values are stored
//  as JSON strings exactly as the script serialized them, preserving type fidelity (numbers,
//  objects, booleans, null) the way Tampermonkey does.
//
//  An actor: the message router and the (future) background runner both touch it concurrently.
//

import Foundation

actor GMValueStore {

    /// In-memory cache of each script's value map (jsonKey → json-encoded value string).
    private var caches: [UUID: [String: String]] = [:]
    private let defaults: UserDefaults

    init(suiteName: String = "com.brownbear.gmstore") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - Single value

    /// The JSON-encoded value for `key`, or nil if unset.
    func value(scriptID: UUID, key: String) -> String? {
        map(for: scriptID)[key]
    }

    /// Set `key` to a JSON-encoded value string.
    func setValue(scriptID: UUID, key: String, jsonValue: String) {
        var values = map(for: scriptID)
        values[key] = jsonValue
        commit(values, for: scriptID)
    }

    func deleteValue(scriptID: UUID, key: String) {
        var values = map(for: scriptID)
        values.removeValue(forKey: key)
        commit(values, for: scriptID)
    }

    func listValues(scriptID: UUID) -> [String] {
        Array(map(for: scriptID).keys)
    }

    /// The complete namespace, used to seed the sandbox so GM_getValue can be synchronous.
    func snapshot(scriptID: UUID) -> [String: String] {
        map(for: scriptID)
    }

    // MARK: - Batch

    func setValues(scriptID: UUID, entries: [String: String]) {
        var values = map(for: scriptID)
        for (key, json) in entries { values[key] = json }
        commit(values, for: scriptID)
    }

    func deleteValues(scriptID: UUID, keys: [String]) {
        var values = map(for: scriptID)
        for key in keys { values.removeValue(forKey: key) }
        commit(values, for: scriptID)
    }

    /// Remove a script's entire namespace (called when a script is uninstalled).
    func clear(scriptID: UUID) {
        caches[scriptID] = [:]
        defaults.removeObject(forKey: storageKey(scriptID))
    }

    // MARK: - Backing

    private func storageKey(_ scriptID: UUID) -> String { "gm.\(scriptID.uuidString)" }

    private func map(for scriptID: UUID) -> [String: String] {
        if let cached = caches[scriptID] { return cached }
        let loaded: [String: String]
        if let data = defaults.data(forKey: storageKey(scriptID)),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            loaded = decoded
        } else {
            loaded = [:]
        }
        caches[scriptID] = loaded
        return loaded
    }

    private func commit(_ values: [String: String], for scriptID: UUID) {
        caches[scriptID] = values
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: storageKey(scriptID))
        }
    }
}
