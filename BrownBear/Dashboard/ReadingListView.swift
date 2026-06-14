//
//  ReadingListView.swift
//  BrownBear
//
//  The "read later" list, presented as a sheet from the browser menu. Tap an item to open it (and mark it
//  read), swipe to delete, swipe the other way to toggle read/unread. Reads/writes the shared
//  ReadingListStore so changes are live across the app.
//

import SwiftUI
import UIKit

struct ReadingListView: View {

    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var items: [ReadingListItem] = []

    private var store: ReadingListStore { BrownBearServices.shared.readingListStore }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    DashboardEmptyState(
                        systemImage: "eyeglasses",
                        title: "Nothing to read yet",
                        message: "Choose “Add to Reading List” in the ••• menu to save a page for later."
                    )
                } else {
                    List {
                        ForEach(items) { item in
                            Button { open(item) } label: {
                                ReadingListRowView(item: item)
                            }
                            .listRowBackground(BBTheme.Color.card)
                            .swipeActions(edge: .leading) {
                                Button { toggleRead(item) } label: {
                                    Label(item.isRead ? "Unread" : "Read",
                                          systemImage: item.isRead ? "circle" : "checkmark.circle")
                                }
                                .tint(BBTheme.Color.accent)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(BBTheme.backgroundGradient)
            .navigationTitle("Reading List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: onClose).fontWeight(.semibold)
                }
            }
        }
        .task { items = await store.all() }
    }

    private func open(_ item: ReadingListItem) {
        Task { await store.setRead(id: item.id, true) }
        onOpen(item.url)
    }

    private func toggleRead(_ item: ReadingListItem) {
        guard let index = items.firstIndex(of: item) else { return }
        items[index].isRead.toggle()
        let isRead = items[index].isRead
        Task { await store.setRead(id: item.id, isRead) }
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { items[$0].id }
        items.remove(atOffsets: offsets)
        Task { for id in ids { await store.remove(id: id) } }
    }
}

private struct ReadingListRowView: View {
    let item: ReadingListItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isRead ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(item.isRead ? BBTheme.Color.textSecondary : BBTheme.Color.accent)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.body.weight(item.isRead ? .regular : .semibold))
                    .foregroundStyle(item.isRead ? BBTheme.Color.textSecondary : BBTheme.Color.textPrimary)
                    .lineLimit(1)
                Text(item.url.host ?? item.url.absoluteString)
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

extension ReadingListView {
    /// Wrap the list in a hosting controller wired to dismiss itself; `onOpen` fires after dismissal.
    static func makeHostingController(onOpen: @escaping (URL) -> Void) -> UIViewController {
        var hosting: UIHostingController<ReadingListView>?
        let view = ReadingListView(
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
