//
//  ScriptRowView.swift
//  BrownBear
//
//  A single installed-script row in the dashboard list: name, a short match summary, a background
//  badge when applicable, and an enable/disable toggle wired to the shared store.
//

import SwiftUI

struct ScriptRowView: View {

    let script: UserScript
    @ObservedObject var model: DashboardViewModel

    private var matchSummary: String {
        let meta = script.metadata
        if meta.runsInBackground { return meta.crontabs.first ?? "background script" }
        let rules = meta.matches + meta.includes
        if rules.isEmpty { return "no match rules" }
        return rules.count == 1 ? rules[0] : "\(rules[0]) +\(rules.count - 1) more"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(script.enabled ? BBTheme.Color.secure : BBTheme.Color.textSecondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BBTheme.Color.textPrimary)
                        .lineLimit(1)
                    if script.metadata.runsInBackground {
                        BBPill("BG", systemImage: "clock.arrow.circlepath")
                    }
                }
                Text(matchSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(BBTheme.Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { script.enabled },
                set: { newValue in Task { await model.setEnabled(script, newValue) } }
            ))
            .labelsHidden()
            .tint(BBTheme.Color.accent)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
