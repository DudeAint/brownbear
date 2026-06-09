//
//  WebExtensionBrowserData.swift
//  BrownBear
//
//  Pure shape mappers for the read-only browser-data extension APIs — chrome.bookmarks,
//  chrome.history, and chrome.sessions — backed by BrownBear's own BookmarkStore / HistoryStore /
//  TabManager.recentlyClosed. These produce the exact object shapes Chrome's APIs return so an
//  extension (e.g. Vimium's Vomnibar + 'u' tab-restore, which call chrome.bookmarks.getTree /
//  chrome.history.search / chrome.sessions.restore UNGUARDED) sees real data instead of a TypeError.
//
//  Pure value transforms only (no UIKit, no I/O) so they're unit-tested directly; the bridge host
//  reads the stores on the main actor and hands the models here. The native bridge gates each call on
//  the matching manifest permission (bookmarks/history/sessions) before any of this runs — these
//  expose the user's browsing data, so a script without the declared permission gets nothing (§5).
//
//  Coverage is intentionally the read surface real extensions use: bookmarks.getTree/get/search;
//  history.search/getVisits/addUrl-deleteUrl are owner ops we don't fabricate; sessions.getRecentlyClosed
//  + restore. Write ops we can't honor faithfully are not stubbed as success — see the bridge.
//

import Foundation

enum WebExtensionBrowserData {

    /// The manifest permission a browser-data method requires, or nil if none (none here are permission-free).
    /// Used by the native bridge to fail closed before reading any user data.
    static func requiredPermission(forMethod method: String) -> String? {
        if method.hasPrefix("bookmarks.") { return "bookmarks" }
        if method.hasPrefix("history.") { return "history" }
        if method.hasPrefix("sessions.") { return "sessions" }
        return nil
    }

    // MARK: - chrome.bookmarks

    /// chrome.bookmarks.getTree → `[rootNode]`. BrownBear has a flat bookmark list, so we present the
    /// Chrome-shaped hierarchy extensions expect: a root ("0") containing one "Bookmarks" folder ("1")
    /// whose children are the user's bookmarks as URL leaves. A recursive walker (Vimium's completer)
    /// flattens this exactly as it would Chrome's real tree.
    static func bookmarkTree(from bookmarks: [Bookmark]) -> [[String: Any]] {
        let leaves: [[String: Any]] = bookmarks.enumerated().map { index, bm in
            [
                "id": bm.id.uuidString,
                "parentId": "1",
                "index": index,
                "title": bm.displayTitle,
                "url": bm.url.absoluteString,
                "dateAdded": Int(bm.createdAt.timeIntervalSince1970 * 1000)
            ]
        }
        let folder: [String: Any] = [
            "id": "1", "parentId": "0", "index": 0, "title": "Bookmarks", "children": leaves
        ]
        let root: [String: Any] = ["id": "0", "title": "", "children": [folder]]
        return [root]
    }

    /// chrome.bookmarks.search(query) → flat list of matching URL leaves (title or URL contains the
    /// query, case-insensitive). Chrome also accepts an object `{query,url,title}`; we honor the text.
    static func bookmarkSearch(_ query: String, in bookmarks: [Bookmark]) -> [[String: Any]] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = needle.isEmpty ? bookmarks : bookmarks.filter {
            $0.displayTitle.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle)
        }
        return matched.enumerated().map { index, bm in
            ["id": bm.id.uuidString, "parentId": "1", "index": index,
             "title": bm.displayTitle, "url": bm.url.absoluteString,
             "dateAdded": Int(bm.createdAt.timeIntervalSince1970 * 1000)]
        }
    }

    // MARK: - chrome.history

    /// chrome.history.search → `HistoryItem[]`. Maps BrownBear's HistoryEntry to Chrome's shape
    /// (lastVisitTime in epoch ms; typedCount unknown on iOS → 0). The caller applies the query/limit
    /// via HistoryStore.search; this just shapes the rows.
    static func historyItems(from entries: [HistoryEntry]) -> [[String: Any]] {
        entries.map { entry in
            [
                "id": entry.id.uuidString,
                "url": entry.url.absoluteString,
                "title": entry.title,
                "lastVisitTime": entry.lastVisit.timeIntervalSince1970 * 1000,
                "visitCount": entry.visitCount,
                "typedCount": 0
            ]
        }
    }

    // MARK: - chrome.sessions

    /// chrome.sessions.getRecentlyClosed → `Session[]`. Each closed tab becomes a `{lastModified, tab}`
    /// session. BrownBear's closed-tab record has no timestamp, so lastModified is 0 (honest: unknown),
    /// and the tab carries the fields a restorer reads (url/title); id is the synthetic closed-tab index
    /// used as the sessionId for restore.
    static func sessionRecords(from closed: [TabManager.ClosedTabRecord]) -> [[String: Any]] {
        closed.enumerated().map { index, record in
            [
                "lastModified": 0,
                "tab": [
                    "sessionId": "closed-\(index)",
                    "url": record.url.absoluteString,
                    "title": record.title,
                    "windowId": 1,
                    "index": index
                ] as [String: Any]
            ]
        }
    }

    /// Resolve a sessions.restore(sessionId) to the index into recentlyClosed it refers to. Chrome's
    /// restore with no id reopens the most recently closed (index 0); our ids are "closed-<index>".
    static func restoreIndex(sessionId: String?, closedCount: Int) -> Int? {
        guard closedCount > 0 else { return nil }
        guard let sessionId, !sessionId.isEmpty else { return 0 }   // no id → most recent
        if let n = Int(sessionId.replacingOccurrences(of: "closed-", with: "")), n >= 0, n < closedCount {
            return n
        }
        return nil
    }
}
