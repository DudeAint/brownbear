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
    @State private var storedValues: [(key: String, value: String)] = []
    @State private var editingKey: String?
    @State private var editingText = ""
    @State private var valueError: String?
    /// Hosts the user allowed beyond the script's @connect (ScriptCat-style), each revocable here.
    @State private var grantedHosts: [String] = []

    private var meta: ScriptMetadata { script.metadata }
    private var connectGrantStore: ConnectGrantStore { BrownBearServices.shared.connectGrantStore }
    private var current: UserScript { model.scripts.first { $0.id == script.id } ?? script }

    private var valueStore: GMValueStore { BrownBearServices.shared.valueStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBTheme.Metric.sectionSpacing) {
                headerCard
                if meta.runsInBackground { scheduleCard }
                ScriptSettingsCard(script: current, model: model)
                directivesCard
                if !grantedHosts.isEmpty { grantedHostsCard }
                storedValuesCard
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
        .alert("Edit value", isPresented: Binding(
            get: { editingKey != nil },
            set: { if !$0 { editingKey = nil } }
        )) {
            TextField("JSON value", text: $editingText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") { saveEditedValue() }
            Button("Cancel", role: .cancel) { editingKey = nil }
        } message: {
            Text(editingKey.map(editMessage) ?? "")
        }
        .alert("Invalid JSON", isPresented: Binding(
            get: { valueError != nil },
            set: { if !$0 { valueError = nil } }
        )) {
            Button("OK") { valueError = nil }
        } message: {
            Text(valueError ?? "")
        }
        .task {
            logs = await model.logs(for: script.id)
            await reloadStoredValues()
            await reloadGrantedHosts()
        }
    }

    private func reloadGrantedHosts() async {
        grantedHosts = await connectGrantStore.allowedHosts(scriptID: script.id)
    }

    /// "Allowed by you" — hosts the user granted at the @connect prompt beyond what the script
    /// declares. Each is revocable; declared @connect hosts stay as read-only pills in directivesCard.
    private var grantedHostsCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Allowed by you", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                Text("Hosts you let this script connect to beyond its @connect list.")
                    .font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
                ForEach(grantedHosts, id: \.self) { host in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(BBTheme.Color.textSecondary)
                        Text(host).font(.caption.monospaced()).foregroundStyle(BBTheme.Color.textPrimary)
                        Spacer()
                        Button(role: .destructive) {
                            Task { @MainActor in
                                await connectGrantStore.revoke(scriptID: script.id, host: host)
                                await reloadGrantedHosts()
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(BBTheme.Color.textSecondary)
                        }
                        .accessibilityLabel("Revoke \(host)")
                    }
                    if host != grantedHosts.last {
                        Divider().overlay(BBTheme.Color.separator.opacity(0.5))
                    }
                }
            }
        }
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
                    .labelsHidden().tint(BBTheme.Color.toggleOn)
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

    /// GM_setValue storage inspector — view/edit/delete the script's namespaced values, the
    /// Tampermonkey "Storage" tab that's indispensable for debugging a script whose state is wrong.
    private var storedValuesCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Stored values", systemImage: "externaldrive")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                    Spacer()
                    if !storedValues.isEmpty {
                        Text("\(storedValues.count)")
                            .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                    }
                }
                if storedValues.isEmpty {
                    Text("This script hasn't stored any values with GM_setValue.")
                        .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
                } else {
                    ForEach(storedValues, id: \.key) { entry in
                        storedValueRow(key: entry.key, value: entry.value)
                        if entry.key != storedValues.last?.key {
                            Divider().overlay(BBTheme.Color.separator.opacity(0.5))
                        }
                    }
                    Button(role: .destructive) {
                        Task { @MainActor in await valueStore.clear(scriptID: script.id); await reloadStoredValues() }
                    } label: {
                        Label("Clear all values", systemImage: "trash").font(.caption.weight(.semibold))
                    }
                    .tint(BBTheme.Color.destructive)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func storedValueRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key).font(.caption.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                Text(value).font(.caption2.monospaced()).foregroundStyle(BBTheme.Color.textSecondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Menu {
                Button { beginEditing(key: key, value: value) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) {
                    Task { @MainActor in
                        await valueStore.deleteValue(scriptID: script.id, key: key)
                        await reloadStoredValues()
                    }
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(BBTheme.Color.textSecondary).padding(.vertical, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func beginEditing(key: String, value: String) {
        editingText = value
        editingKey = key
    }

    private func editMessage(for key: String) -> String {
        "Stored under “\(key)”. Enter a valid JSON value — a quoted string, number, boolean, or object."
    }

    /// Validate the edited text as JSON (fragments allowed, matching how GM_setValue serializes) and
    /// persist it. Reject invalid JSON so the store never holds a value the sandbox can't parse back.
    private func saveEditedValue() {
        guard let key = editingKey else { return }
        editingKey = nil
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            valueError = "“\(trimmed)” isn't valid JSON. Wrap strings in quotes, e.g. \"hello\"."
            return
        }
        Task { @MainActor in
            let old = await valueStore.setValueReturningOld(scriptID: script.id, key: key, jsonValue: trimmed)
            // Push the edit into any open page running this script (live GM_getValue / value-change
            // listeners), so a dashboard edit doesn't require a reload — TM/VM cross-context parity. The
            // foreground InjectionOrchestrator observes this and broadcasts; a no-op if no page is open.
            NotificationCenter.default.post(
                name: .brownBearGMValueChangedExternally,
                object: GMValueChangeBroadcast(scriptID: script.id,
                                               changes: [GMValueChange(key: key, old: old, new: trimmed)]))
            await reloadStoredValues()
        }
    }

    private func reloadStoredValues() async {
        let snapshot = await valueStore.snapshot(scriptID: script.id)
        storedValues = snapshot.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
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
