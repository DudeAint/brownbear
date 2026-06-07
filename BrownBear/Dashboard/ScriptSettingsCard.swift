//
//  ScriptSettingsCard.swift
//  BrownBear
//
//  The Tampermonkey/ScriptCat "script settings" surface, shown inside ScriptDetailView. Lets the
//  user override a single script's injection timing, execution context, and auto-update
//  participation without editing its source, and run a manual update check. Every override defaults
//  to "follow what the script declares"; clearing a row reverts to the script's own @metadata.
//

import SwiftUI

struct ScriptSettingsCard: View {

    /// The live record (passed as `current` from the detail view, so it tracks model changes).
    let script: UserScript
    @ObservedObject var model: DashboardViewModel

    @State private var checkingUpdate = false
    @State private var updateResult: String?

    private var meta: ScriptMetadata { script.metadata }
    /// A manual update check is only meaningful if the script declares where to fetch from.
    private var hasUpdateURL: Bool { meta.downloadURL != nil || meta.updateURL != nil }

    var body: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Script settings", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)

                settingPicker("Injection timing", selection: runAtBinding) {
                    Text("Default (\(meta.runAt.rawValue))").tag(RunAt?.none)
                    ForEach(RunAt.allCases, id: \.self) { Text($0.rawValue).tag(RunAt?.some($0)) }
                }
                settingPicker("Execution context", selection: injectIntoBinding) {
                    Text("Default (\(meta.injectInto.rawValue))").tag(InjectInto?.none)
                    ForEach(InjectInto.allCases, id: \.self) { Text($0.rawValue).tag(InjectInto?.some($0)) }
                }
                settingPicker("Automatic updates", selection: autoUpdateBinding) {
                    Text("Use default").tag(Bool?.none)
                    Text("Enabled").tag(Bool?.some(true))
                    Text("Disabled").tag(Bool?.some(false))
                }

                Divider().overlay(BBTheme.Color.separator.opacity(0.5))
                if hasUpdateURL {
                    updateCheckButton
                } else {
                    Text("This script declares no @updateURL/@downloadURL, so it can't be auto-updated.")
                        .font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
        }
        .alert("Updates", isPresented: Binding(
            get: { updateResult != nil },
            set: { if !$0 { updateResult = nil } }
        )) {
            Button("OK") { updateResult = nil }
        } message: {
            Text(updateResult ?? "")
        }
    }

    private var updateCheckButton: some View {
        Button {
            Task { @MainActor in await runUpdateCheck() }
        } label: {
            HStack(spacing: 8) {
                Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                Spacer()
                if checkingUpdate { ProgressView().controlSize(.small) }
            }
        }
        .disabled(checkingUpdate)
        .tint(BBTheme.Color.accent)
    }

    /// A label + trailing menu-style picker row, styled to match the card's other rows.
    private func settingPicker<Selection: Hashable, Content: View>(
        _ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(BBTheme.Color.textSecondary)
            Spacer()
            Picker(title, selection: selection, content: content)
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(BBTheme.Color.accent)
        }
    }

    // MARK: - Override bindings

    /// Merge one field into the current overrides and persist. Reads `script.overrides` so
    /// successive edits compose instead of clobbering one another.
    private func applyOverride(_ mutate: @escaping (inout ScriptOverrides) -> Void) {
        var overrides = script.overrides ?? ScriptOverrides()
        mutate(&overrides)
        let target = script
        Task { @MainActor in await model.setOverrides(target, overrides) }
    }

    private var runAtBinding: Binding<RunAt?> {
        Binding(get: { script.overrides?.runAt }, set: { value in applyOverride { $0.runAt = value } })
    }

    private var injectIntoBinding: Binding<InjectInto?> {
        Binding(get: { script.overrides?.injectInto }, set: { value in applyOverride { $0.injectInto = value } })
    }

    private var autoUpdateBinding: Binding<Bool?> {
        Binding(get: { script.overrides?.autoUpdate }, set: { value in applyOverride { $0.autoUpdate = value } })
    }

    /// Run a manual single-script update check and report the outcome via the "Updates" alert.
    private func runUpdateCheck() async {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        let outcome = await model.checkForUpdate(script)
        checkingUpdate = false
        switch outcome {
        case .updated(let version): updateResult = "Updated to v\(version)."
        case .upToDate: updateResult = "“\(meta.displayName)” is already up to date."
        case .noURL: updateResult = "This script declares no @updateURL or @downloadURL to check."
        case .failed: updateResult = "Couldn't check for updates. Check your connection and try again."
        }
    }
}
