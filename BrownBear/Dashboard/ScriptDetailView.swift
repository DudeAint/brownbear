//
//  ScriptDetailView.swift
//  BrownBear
//
//  Inspect one script: its metadata (matches, grants, schedule), background run state, recent
//  log output, and actions to enable/disable, edit, or delete.
//

import SwiftUI

struct ScriptDetailView: View {

    let script: UserScript
    @ObservedObject var model: DashboardViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var logs: [LogEntry] = []
    @State private var editing = false
    @State private var confirmingDelete = false

    private var meta: ScriptMetadata { script.metadata }
    private var current: UserScript { model.scripts.first { $0.id == script.id } ?? script }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBTheme.Metric.sectionSpacing) {
                headerCard
                if meta.runsInBackground { scheduleCard }
                directivesCard
                logsCard
                deleteButton
            }
            .padding(16)
        }
        .background(BBTheme.backgroundGradient)
        .navigationTitle(meta.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { editing = true }.fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $editing) {
            ScriptEditorScreen(model: model, existing: current)
        }
        .task { logs = await model.logs(for: script.id) }
    }

    private var headerCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.displayName).font(.headline).foregroundStyle(BBTheme.Color.textPrimary)
                        if let version = meta.version {
                            Text("v\(version)" + (meta.author.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { current.enabled },
                        set: { newValue in Task { await model.setEnabled(current, newValue) } }
                    ))
                    .labelsHidden().tint(BBTheme.Color.accent)
                }
                if let description = meta.descriptionText, !description.isEmpty {
                    Text(description).font(.subheadline).foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
        }
    }

    private var scheduleCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Background schedule", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                ForEach(meta.crontabs, id: \.self) { expression in
                    Text(expression).font(.caption.monospaced()).foregroundStyle(BBTheme.Color.accent)
                }
                HStack {
                    runStat("Last run", BBFormat.relative(model.scheduleState(for: current)?.lastFire))
                    Spacer()
                    runStat("Next due", BBFormat.relative(model.nextFire(for: current)))
                }
                Text("iOS runs background scripts on a best-effort schedule, not in real time.")
                    .font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
            }
        }
    }

    private func runStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
        }
    }

    private var directivesCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 12) {
                directiveRow("Runs at", values: [meta.runAt.rawValue])
                if !meta.matches.isEmpty { directiveRow("@match", values: meta.matches) }
                if !meta.includes.isEmpty { directiveRow("@include", values: meta.includes) }
                if !meta.excludes.isEmpty { directiveRow("@exclude", values: meta.excludes) }
                directiveRow("@grant", values: meta.grantsNone ? ["none"] : (meta.grants.isEmpty ? ["—"] : meta.grants))
                if !meta.connects.isEmpty { directiveRow("@connect", values: meta.connects) }
            }
        }
    }

    private func directiveRow(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(BBTheme.Color.textSecondary)
            FlowLayout(spacing: 6) {
                ForEach(values, id: \.self) { BBPill($0) }
            }
        }
    }

    private var logsCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recent output", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                if logs.isEmpty {
                    Text("No log output yet.").font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                } else {
                    ForEach(logs.prefix(40)) { LogLineView(entry: $0) }
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Label("Delete script", systemImage: "trash").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(BBTheme.Color.destructive)
        .confirmationDialog("Delete “\(meta.displayName)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await model.delete(script); dismiss() }
            }
        } message: {
            Text("This removes the script and its stored values and logs.")
        }
    }
}
