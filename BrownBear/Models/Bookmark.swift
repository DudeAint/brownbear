//
//  Bookmark.swift
//  BrownBear
//
//  A saved page. Pure value type, persisted by BookmarkStore. Folders/ordering are a later add;
//  v1 is a flat, newest-first list.
//

import Foundation

struct Bookmark: Codable, Identifiable, Equatable {

    let id: UUID
    var title: String
    var url: URL
    let createdAt: Date

    init(id: UUID = UUID(), title: String, url: URL, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }

    /// A display title that never renders empty — falls back to the host, then the raw URL.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return url.host ?? url.absoluteString
    }
}
