//
//  ReadingListItem.swift
//  BrownBear
//
//  A page saved to read later (Safari's Reading List). Distinct from a bookmark: it carries a read/unread
//  state and is meant to be cleared as you work through it, not kept forever. Pure value type, persisted
//  by ReadingListStore.
//

import Foundation

struct ReadingListItem: Codable, Identifiable, Equatable {

    let id: UUID
    var title: String
    var url: URL
    let addedAt: Date
    var isRead: Bool

    init(id: UUID = UUID(), title: String, url: URL, addedAt: Date = Date(), isRead: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.addedAt = addedAt
        self.isRead = isRead
    }

    /// A display title that never renders empty — falls back to the host, then the raw URL.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return url.host ?? url.absoluteString
    }
}
