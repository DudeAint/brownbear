//
//  HistoryEntry.swift
//  BrownBear
//
//  A single visited page in browsing history. Pure value type, persisted by HistoryStore. One
//  entry per normalized URL; repeat visits bump `visitCount` and `lastVisit` rather than appending
//  duplicates, so the store stays compact and frecency ranking has real signal to work with.
//

import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {

    let id: UUID
    var url: URL
    var title: String
    var visitCount: Int
    var firstVisit: Date
    var lastVisit: Date

    init(id: UUID = UUID(),
         url: URL,
         title: String,
         visitCount: Int = 1,
         firstVisit: Date = Date(),
         lastVisit: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.firstVisit = firstVisit
        self.lastVisit = lastVisit
    }

    /// A display title that never renders empty — falls back to the host, then the raw URL.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return url.host ?? url.absoluteString
    }

    /// Host without a leading "www." for compact display.
    var displayHost: String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Frecency: visit frequency weighted by recency, the ranking Firefox/Chrome use for the
    /// awesome-bar and top sites. Recent + frequently-visited pages float to the top; stale
    /// pages decay. `now` is injected so the score is a pure function (testable, deterministic).
    func frecency(now: Date = Date()) -> Double {
        let age = now.timeIntervalSince(lastVisit)
        let day: TimeInterval = 86_400
        let recencyWeight: Double
        switch age {
        case ..<day:          recencyWeight = 4.0      // today
        case ..<(7 * day):    recencyWeight = 2.0      // this week
        case ..<(30 * day):   recencyWeight = 1.0      // this month
        case ..<(90 * day):   recencyWeight = 0.5      // this quarter
        default:              recencyWeight = 0.25     // older
        }
        return Double(visitCount) * recencyWeight
    }
}
