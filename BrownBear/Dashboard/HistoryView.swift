//
//  HistoryView.swift
//  BrownBear
//
//  Browsing history, presented as a sheet from the browser menu. Searchable (title + URL), tap to
//  open, swipe to delete a single entry, and a Clear menu (last hour / today / everything). Reads
//  and writes the shared HistoryStore so changes are live across the app. Entries are grouped by
//  day, newest first — the Safari/Chrome history layout.
//

import SwiftUI
import UIKit

struct HistoryView: View {

    /// Open an entry's URL (the host dismisses first, then calls this).
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var entries: [HistoryEntry] = []
    @State private var query = ""

    private var store: HistoryStore { BrownBearServices.shared.historyStore }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    DashboardEmptyState(
                        systemImage: "clock.arrow.circlepath",
                        title: query.isEmpty ? "No history yet" : "No matches",
                        message: query.isEmpty
                            ? "Pages you visit will appear here so you can find them again."
                            : "No visited page matches “\(query)”.")
                } else {
                    List {
                        ForEach(groupedEntries, id: \.key) { group in
                            Section(group.label) {
                                ForEach(group.entries) { entry in
                                    Button { onOpen(entry.url) } label: {
                                        HistoryRowView(entry: entry)
                                    }
                                    .listRowBackground(BBTheme.Color.card)
                                }
                                .onDelete { offsets in delete(in: group.entries, offsets) }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(BBTheme.backgroundGradient)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done", action: onClose).fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) { clear(since: .hourAgo) } label: {
                            Label("Clear last hour", systemImage: "clock")
                        }
                        Button(role: .destructive) { clear(since: .startOfToday) } label: {
                            Label("Clear today", systemImage: "calendar")
                        }
                        Button(role: .destructive) { clearAll() } label: {
                            Label("Clear all history", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(entries.isEmpty)
                }
            }
        }
        .tint(BBTheme.Color.accent)
        .task { await reload() }
        .onChange(of: query) { _ in Task { await reload() } }
    }

    // MARK: - Grouping

    private struct DayGroup { let key: String; let label: String; let entries: [HistoryEntry] }

    /// Entries bucketed by calendar day, newest day first; entries within a day stay newest-first.
    private var groupedEntries: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.lastVisit) }
        return grouped
            .sorted { $0.key > $1.key }
            .map { day, items in
                DayGroup(key: ISO8601DateFormatter().string(from: day),
                         label: Self.dayLabel(day, calendar: calendar),
                         entries: items.sorted { $0.lastVisit > $1.lastVisit })
            }
    }

    private static func dayLabel(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    // MARK: - Data

    private func reload() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = trimmed.isEmpty ? await store.all() : await store.search(trimmed, limit: 500)
    }

    private func delete(in groupEntries: [HistoryEntry], _ offsets: IndexSet) {
        let ids = offsets.map { groupEntries[$0].id }
        entries.removeAll { ids.contains($0.id) }
        Task { for id in ids { await store.remove(id: id) } }
    }

    private func clear(since date: Date) {
        Task {
            await store.removeEntries(since: date)
            await reload()
        }
    }

    private func clearAll() {
        Task {
            await store.clear()
            await reload()
        }
    }
}

private extension Date {
    static var hourAgo: Date { Date().addingTimeInterval(-3_600) }
    static var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
}

private struct HistoryRowView: View {
    let entry: HistoryEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BBTheme.Color.accent)
                .frame(width: 30, height: 30)
                .background(BBTheme.Color.accent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                    .lineLimit(1)
                Text(entry.displayHost)
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(entry.lastVisit, style: .time)
                .font(.caption2)
                .foregroundStyle(BBTheme.Color.textSecondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - UIKit presentation

extension HistoryView {
    /// Wrap the list in a hosting controller wired to dismiss itself; `onOpen` fires after dismissal.
    static func makeHostingController(onOpen: @escaping (URL) -> Void) -> UIViewController {
        var hosting: UIHostingController<HistoryView>?
        let view = HistoryView(
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
