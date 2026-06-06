//
//  BookmarksView.swift
//  BrownBear
//
//  The saved-pages list, presented as a sheet from the browser menu. Tap a bookmark to open it,
//  swipe to delete. Reads/writes the shared BookmarkStore so changes are live across the app.
//

import SwiftUI
import UIKit

struct BookmarksView: View {

    /// Open a bookmark's URL (the host dismisses first, then calls this).
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var bookmarks: [Bookmark] = []

    private var store: BookmarkStore { BrownBearServices.shared.bookmarkStore }

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    DashboardEmptyState(
                        systemImage: "bookmark",
                        title: "No bookmarks yet",
                        message: "Tap the star in the ••• menu to save the current page here."
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button { onOpen(bookmark.url) } label: {
                                BookmarkRowView(bookmark: bookmark)
                            }
                            .listRowBackground(BBTheme.Color.card)
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(BBTheme.backgroundGradient)
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: onClose).fontWeight(.semibold)
                }
            }
        }
        .task { bookmarks = await store.all() }
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { bookmarks[$0].id }
        bookmarks.remove(atOffsets: offsets)
        Task { for id in ids { await store.remove(id: id) } }
    }
}

private struct BookmarkRowView: View {
    let bookmark: Bookmark
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BBTheme.Color.accent)
                .frame(width: 30, height: 30)
                .background(BBTheme.Color.accent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                    .lineLimit(1)
                Text(bookmark.url.host ?? bookmark.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - UIKit presentation

extension BookmarksView {
    /// Wrap the list in a hosting controller wired to dismiss itself; `onOpen` fires after dismissal.
    static func makeHostingController(onOpen: @escaping (URL) -> Void) -> UIViewController {
        var hosting: UIHostingController<BookmarksView>?
        let view = BookmarksView(
            onOpen: { url in hosting?.dismiss(animated: true) { onOpen(url) } },
            onClose: { hosting?.dismiss(animated: true) })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        hosting = controller
        return controller
    }
}
