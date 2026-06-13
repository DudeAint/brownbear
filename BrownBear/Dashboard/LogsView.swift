//
//  LogsView.swift
//  BrownBear
//
//  The execution log viewer, now split into two tabs: "Console" (every line of GM_log/console output and
//  background run results) and "Network" (each GM_xmlhttpRequest / fetch / XHR — domain + status + type in
//  a collapsed row, tap the arrow to see the full request/response detail).
//

import SwiftUI
import UIKit

struct LogsView: View {

    @ObservedObject var model: DashboardViewModel
    @AppStorage(PageConsoleHandler.captureDefaultsKey) private var capturePageConsole = true
    @AppStorage("bbAlwaysOpenResponse") private var alwaysOpenResponse = false
    @State private var section: LogTab = .console

    /// The two tabs inside the Logs screen.
    enum LogTab: String, CaseIterable, Identifiable {
        case console = "Console"
        case network = "Network"
        var id: String { rawValue }
    }

    private var searchPrompt: String {
        section == .console ? "Search logs" : "Search requests"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(LogTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch section {
            case .console: consoleSection
            case .network: NetworkLogList(model: model)
            }
        }
        .background(BBTheme.backgroundGradient)
        .searchable(text: section == .console ? $model.logSearch : $model.networkSearch,
                    prompt: Text(searchPrompt))
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if section == .console {
                        Toggle(isOn: $capturePageConsole) {
                            Label("Capture page console", systemImage: "doc.text.magnifyingglass")
                        }
                        Button(role: .destructive) {
                            Task { await model.clearAllLogs() }
                        } label: {
                            Label("Clear logs", systemImage: "trash")
                        }
                        .disabled(model.recentLogs.isEmpty)
                    } else {
                        Toggle(isOn: $alwaysOpenResponse) {
                            Label("Always open response", systemImage: "chevron.down.square")
                        }
                        Button(role: .destructive) {
                            Task { await model.clearNetworkLogs() }
                        } label: {
                            Label("Clear network log", systemImage: "trash")
                        }
                        .disabled(model.recentNetworkLogs.isEmpty)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - Console tab

    @ViewBuilder
    private var consoleSection: some View {
        if model.recentLogs.isEmpty {
            DashboardEmptyState(
                systemImage: "list.bullet.rectangle",
                title: "No logs yet",
                message: "Output from your scripts — GM_log, console.log, and background runs — appears here."
            )
        } else {
            VStack(spacing: 0) {
                Picker("Filter", selection: $model.logFilter) {
                    ForEach(LogFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                if model.filteredLogs.isEmpty {
                    DashboardEmptyState(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "No matching logs",
                        message: model.logSearch.isEmpty
                            ? "No entries match the “\(model.logFilter.title)” filter."
                            : "No entries match “\(model.logSearch)”."
                    )
                } else {
                    // One UITextView holding the whole filtered log gives native cross-line selection,
                    // the magnifier, Select All, and Copy — SwiftUI Text can only select one line.
                    SelectableLogTextView(logs: model.filteredLogs)
                }
            }
        }
    }
}

// MARK: - Network tab

/// The Network tab: a list of recent requests, newest first, each an expandable row.
struct NetworkLogList: View {
    @ObservedObject var model: DashboardViewModel

    var body: some View {
        if model.recentNetworkLogs.isEmpty {
            DashboardEmptyState(
                systemImage: "network",
                title: "No network requests yet",
                message: "GM_xmlhttpRequest, fetch, and XHR calls from your scripts and the pages you "
                    + "visit show up here — tap a row's arrow for the full detail."
            )
        } else if model.filteredNetworkLogs.isEmpty {
            DashboardEmptyState(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "No matching requests",
                message: "No requests match “\(model.networkSearch)”."
            )
        } else {
            List {
                ForEach(model.filteredNetworkLogs) { entry in
                    NetworkLogRow(entry: entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(BBTheme.Color.textSecondary.opacity(0.15))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One request: a collapsed summary (status badge · host · method/type/path) that expands to full detail.
struct NetworkLogRow: View {
    let entry: NetworkLogEntry
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            NetworkLogDetail(entry: entry)
                .padding(.top, 4)
        } label: {
            summary
        }
        .tint(BBTheme.Color.textSecondary)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.host)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.method)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(BBTheme.Color.textSecondary)
                    Text(entry.kind.displayName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(BBTheme.Color.accent)
                    if !entry.pathAndQuery.isEmpty {
                        Text(entry.pathAndQuery)
                            .font(.system(size: 11))
                            .foregroundStyle(BBTheme.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        Text(entry.statusCode == 0 ? "ERR" : "\(entry.statusCode)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(statusColor)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var statusColor: Color {
        switch entry.statusCode {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<600: return .red
        default: return entry.error != nil ? .red : .gray
        }
    }
}

/// The expanded detail for one request: the full URL, timing, sizes, and request/response headers/body —
/// all selectable so a single line or the whole block can be copied.
struct NetworkLogDetail: View {
    let entry: NetworkLogEntry
    @AppStorage("bbAlwaysOpenResponse") private var alwaysOpenResponse = false
    /// nil = follow the "Always open response" setting; a value = the user toggled this row's block.
    @State private var responseOverride: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("URL", entry.url)
            field("Method", entry.method)
            field("Type", entry.kind.displayName)
            field("Status", entry.statusCode == 0 ? "— (failed)" : "\(entry.statusCode)")
            if let ms = entry.durationMs { field("Duration", "\(ms) ms") }
            if let bytes = entry.responseBytes { field("Response size", "\(bytes) bytes") }
            if let name = entry.scriptName { field("Script", name) }
            if let error = entry.error { field("Error", error) }
            if !entry.requestHeaders.isEmpty { headers("Request headers", entry.requestHeaders) }
            if let body = entry.requestBody, !body.isEmpty { field("Request body", body) }
            if !entry.responseHeaders.isEmpty { headers("Response headers", entry.responseHeaders) }
            if let body = entry.responseBody, !body.isEmpty { responseSection(body) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    /// The collapsible Response block — a monospaced code block. Starts open when "Always open response"
    /// is on, otherwise the user taps the dropdown to reveal it; a per-row toggle overrides the setting.
    private func responseSection(_ body: String) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { responseOverride ?? alwaysOpenResponse },
                                            set: { responseOverride = $0 })) {
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BBTheme.Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BBTheme.Color.card.opacity(0.7)))
                .padding(.top, 2)
        } label: {
            Text("RESPONSE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BBTheme.Color.textSecondary)
        }
        .tint(BBTheme.Color.textSecondary)
    }

    private func field(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BBTheme.Color.textSecondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(BBTheme.Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headers(_ title: String, _ headers: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BBTheme.Color.textSecondary)
            ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { header in
                Text("\(header.key): \(header.value)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A read-only, fully selectable rendering of the console log as a single scrolling text view.
///
/// SwiftUI can't select across separate `Text` views, so copying "the logs" really meant copying one
/// line. This wraps a `UITextView` (non-editable, selectable) whose attributed string is the whole
/// filtered log — the user can drag across many entries, Select All, and Copy. Colors and the
/// monospaced typography mirror `LogLineView` so it reads identically to the styled list.
struct SelectableLogTextView: UIViewRepresentable {
    let logs: [LogEntry]

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = Self.render(logs)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Re-render on new logs, but keep the user's current selection if it's still in range so a
        // background refresh doesn't yank the highlight out from under a copy gesture.
        let previous = view.selectedRange
        let rendered = Self.render(logs)
        view.attributedText = rendered
        if previous.location + previous.length <= rendered.length {
            view.selectedRange = previous
        }
    }

    /// Build the full attributed log: optional script name, timestamp, then the message in its level
    /// color — one entry per line, blank-line-free so a Select-All copy is compact.
    private static func render(_ logs: [LogEntry]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let body = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let nameFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

        for (index, entry) in logs.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            if let name = entry.scriptName {
                out.append(NSAttributedString(
                    string: name + "\n",
                    attributes: [.font: nameFont, .foregroundColor: BrownBearTheme.Palette.accent]))
            }
            out.append(NSAttributedString(
                string: timeFormatter.string(from: entry.createdAt) + "  ",
                attributes: [.font: body, .foregroundColor: BrownBearTheme.Palette.textSecondary]))
            out.append(NSAttributedString(
                string: entry.message,
                attributes: [.font: body, .foregroundColor: levelColor(entry.level)]))
        }
        return out
    }

    private static func levelColor(_ level: LogEntry.Level) -> UIColor {
        switch level {
        case .error: return BrownBearTheme.Palette.destructive
        case .warn: return BrownBearTheme.Palette.accentBright
        case .info: return BrownBearTheme.Palette.textPrimary
        case .debug: return BrownBearTheme.Palette.textSecondary
        }
    }
}

/// A reusable empty-state placeholder.
struct DashboardEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var action: (() -> Void)?
    var actionTitle: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(BBTheme.Color.accent.opacity(0.7))
            Text(title).font(.headline).foregroundStyle(BBTheme.Color.textPrimary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(BBTheme.Color.textSecondary)
                .padding(.horizontal, 32)
            if let action, let actionTitle {
                Button(action: action) {
                    Text(actionTitle).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(BBTheme.Color.accent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
