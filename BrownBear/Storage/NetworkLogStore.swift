//
//  NetworkLogStore.swift
//  BrownBear
//
//  An in-memory, capped ring of recent network requests for the Logs → Network inspector. Unlike
//  LogStore, this is NOT persisted: a network log is high-volume and may contain auth headers, so it lives
//  for the session only (DevTools-style) and is gone on relaunch. Appends post a debounced change
//  notification so the dashboard can refresh while the Network tab is open without polling.
//

import Foundation

extension Notification.Name {
    /// Posted (coalesced) when the network log changes, so the dashboard re-reads `recent()`.
    static let brownBearNetworkLogDidChange = Notification.Name("brownBearNetworkLogDidChange")
}

/// Thread-safe store of recent network requests. An actor so producers on any queue (the GM URLSession
/// delegate queue, the page-reporter message handler) can append without locking.
actor NetworkLogStore {

    /// Maximum retained requests; older ones are evicted (most-recent-wins).
    private let capacity: Int
    private var entries: [NetworkLogEntry] = []
    /// Coalesces a burst of appends into one notification (a busy page can fire dozens of requests at once).
    private var notifyScheduled = false

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    func append(_ entry: NetworkLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        scheduleNotify()
    }

    /// Most recent requests first, up to `limit`.
    func recent(limit: Int = 300) -> [NetworkLogEntry] {
        Array(entries.suffix(limit).reversed())
    }

    var count: Int { entries.count }

    func clear() {
        entries.removeAll()
        postNotification()
    }

    /// Debounce: fire one notification on the next runloop tick rather than per-append, so a flood of
    /// requests doesn't thrash the dashboard's re-read.
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // 200ms
            await self?.flushNotify()
        }
    }

    private func flushNotify() {
        notifyScheduled = false
        postNotification()
    }

    private nonisolated func postNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .brownBearNetworkLogDidChange, object: nil)
        }
    }
}
