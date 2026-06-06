//
//  LogsView.swift
//  BrownBear
//
//  The execution log viewer — every line of GM_log/console output and background run results,
//  newest first, with the originating script and a level color.
//

import SwiftUI

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
                message: "No entries match the “\(model.logFilter.title)” filter."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.filteredLogs) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            if let name = entry.scriptName {
                                Text(name).font(.caption2.weight(.semibold))
                                    .foregroundStyle(BBTheme.Color.accent)
                            }
                            LogLineView(entry: entry)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        Divider().overlay(BBTheme.Color.separator.opacity(0.5))
                    }
                }
                .padding(.vertical, 8)
            }
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
