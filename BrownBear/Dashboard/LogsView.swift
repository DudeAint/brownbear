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

    var body: some View {
        Group {
            if model.recentLogs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.recentLogs) { entry in
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
        .background(BBTheme.backgroundGradient)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear", role: .destructive) {
                    Task { await model.clearAllLogs() }
                }
                .disabled(model.recentLogs.isEmpty)
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
