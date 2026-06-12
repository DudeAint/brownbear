//
//  TabSessionStore.swift
//  BrownBear
//
//  Persists the open NORMAL tabs (their URL + title, in order) and which one is active, so the browser
//  restores the user's tabs after the app is closed — the Safari/Chrome behavior. Without this, every
//  tab was lost on app close. Private tabs are NEVER persisted (incognito must leave no trace). Backed
//  by UserDefaults: a session is a handful of small records, written on background and read once at launch.
//

import Foundation

@MainActor
enum TabSessionStore {

    /// One restorable tab. `url` is nil for a tab sitting on the built-in New Tab page (no navigation yet).
    /// `id` is the tab's stable id at persist time — the key for its saved thumbnail in TabSnapshotStore.
    /// Optional so sessions written before snapshots existed still decode (their `id` is just nil).
    struct Record: Codable, Equatable {
        let url: String?
        let title: String
        var id: String?
    }

    /// The restored session: the ordered records and the index (within them) of the tab that was active.
    struct Session: Equatable {
        let records: [Record]
        let activeIndex: Int?
    }

    private static let key = "com.brownbear.tabSession.v1"

    /// Persist the current normal-tab session. An empty `records` clears the saved session (so a window
    /// the user emptied doesn't resurrect tabs next launch).
    static func save(records: [Record], activeIndex: Int?) {
        guard !records.isEmpty else { clear(); return }
        let stored = Stored(records: records, activeIndex: activeIndex)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The last persisted session, or an empty one if none/undecodable.
    static func load() -> Session {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Session(records: [], activeIndex: nil)
        }
        return Session(records: stored.records, activeIndex: stored.activeIndex)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private struct Stored: Codable {
        let records: [Record]
        let activeIndex: Int?
    }
}
