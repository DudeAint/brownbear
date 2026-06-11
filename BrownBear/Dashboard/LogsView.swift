//
//  LogsView.swift
//  BrownBear
//
//  The execution log viewer — every line of GM_log/console output and background run results,
//  newest first, with the originating script and a level color.
//

import SwiftUI
import UIKit

struct LogsView: View {

    @ObservedObject var model: DashboardViewModel
    @AppStorage(PageConsoleHandler.captureDefaultsKey) private var capturePageConsole = true

    var body: some View {
        VStack(spacing: 0) {
            if !model.recentLogs.isEmpty {
                Picker("Filter", selection: $model.logFilter) {
                    ForEach(LogFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            content
        }
        .background(BBTheme.backgroundGradient)
        .searchable(text: $model.logSearch, prompt: "Search logs")
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Toggle(isOn: $capturePageConsole) {
                        Label("Capture page console", systemImage: "doc.text.magnifyingglass")
                    }
                    Button(role: .destructive) {
                        Task { await model.clearAllLogs() }
                    } label: {
                        Label("Clear logs", systemImage: "trash")
                    }
                    .disabled(model.recentLogs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.recentLogs.isEmpty {
            emptyState
        } else if model.filteredLogs.isEmpty {
            DashboardEmptyState(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "No matching logs",
                message: model.logSearch.isEmpty
                    ? "No entries match the “\(model.logFilter.title)” filter."
                    : "No entries match “\(model.logSearch)”."
            )
        } else {
            // One UITextView holding the whole filtered log, not a SwiftUI Text per row. SwiftUI's
            // `.textSelection(.enabled)` makes each Text its own selection island — you can only ever
            // drag-select and copy a single line. A read-only UITextView gives native cross-line
            // selection, the magnifier, Select All, and Copy, so the user can grab the entire log at
            // once. The filter Picker stays pinned above (this view scrolls internally).
            SelectableLogTextView(logs: model.filteredLogs)
        }
    }

    private var emptyState: some View {
        DashboardEmptyState(
            systemImage: "list.bullet.rectangle",
            title: "No logs yet",
            message: "Output from your scripts — GM_log, console.log, and background runs — appears here."
        )
    }
}

/// A read-only, fully selectable rendering of the log as a single scrolling text view.
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
