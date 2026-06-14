//
//  TabGroupStore.swift
//  BrownBear
//
//  Persists the user's tab-group DEFINITIONS (id + name + color, in order) so named groups survive an
//  app close — the Safari "tab groups" behavior. Group MEMBERSHIP (which tab is in which group) is
//  persisted separately, on each tab's session record (TabSessionStore.Record.groupID). Backed by
//  UserDefaults: a handful of small records, written on change and read once at launch.
//

import Foundation

@MainActor
enum TabGroupStore {

    private static let key = "com.brownbear.tabGroups.v1"

    /// Persist the group definitions. An empty list clears the saved groups.
    static func save(_ groups: [TabGroup]) {
        guard !groups.isEmpty else { UserDefaults.standard.removeObject(forKey: key); return }
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The last persisted group definitions, or an empty list if none/undecodable.
    static func load() -> [TabGroup] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let groups = try? JSONDecoder().decode([TabGroup].self, from: data) else {
            return []
        }
        return groups
    }
}
