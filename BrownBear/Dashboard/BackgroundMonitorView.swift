//
//  BackgroundMonitorView.swift
//  BrownBear
//
//  Monitors the @crontab/@background scripts: their schedule, last run, and next due time, with an
//  honest note that iOS background execution is best-effort.
//

import SwiftUI

struct BackgroundMonitorView: View {

    @ObservedObject var model: DashboardViewModel
    @State private var running: Set<UUID> = []

    private var scheduler: BrownBearBackgroundScheduler { BrownBearServices.shared.backgroundScheduler }

    var body: some View {
        Group {
            if model.backgroundScripts.isEmpty {
                DashboardEmptyState(
                    systemImage: "clock.arrow.circlepath",
                    title: "No background scripts",
                    message: "Add a script with a @crontab or @background directive and it will run on a schedule, even while the app is closed."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: BBTheme.Metric.sectionSpacing) {
                        infoBanner
                        ForEach(model.backgroundScripts) { script in
                            NavigationLink {
                                ScriptDetailView(script: script, model: model)
                            } label: {
                                BBCard { scheduleRow(script) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(BBTheme.backgroundGradient)
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runNow(_ script: UserScript) {
        running.insert(script.id)
        Task {
            await scheduler.runNow(script)
            await model.load()
            running.remove(script.id)
        }
    }

    private var infoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(BBTheme.Color.accent)
            Text("iOS schedules background work on a best-effort basis. Times shown are targets, not guarantees.")
                .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
        }
        .padding(12)
        .background(BBTheme.Color.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func scheduleRow(_ script: UserScript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(script.displayName).font(.subheadline.weight(.semibold))
                    .foregroundStyle(BBTheme.Color.textPrimary)
                Spacer()
                Circle()
                    .fill(script.enabled ? BBTheme.Color.secure : BBTheme.Color.textSecondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                rowMenu(script)
            }
            FlowLayout(spacing: 6) {
                if script.metadata.isBackground { BBPill("@background", systemImage: "bolt") }
                ForEach(script.metadata.crontabs, id: \.self) { BBPill($0, systemImage: "clock") }
            }
            HStack {
                stat("Last run", BBFormat.relative(model.scheduleState(for: script)?.lastFire))
                Spacer()
                stat("Next due", BBFormat.relative(model.nextFire(for: script)))
            }
            .padding(.top, 2)
        }
    }

    /// Per-schedule actions — Run now, Pause/Resume — satisfying CLAUDE.md §5.6 (schedules must be
    /// user-runnable, pausable, and killable from the dashboard). Pause = disable the script.
    private func rowMenu(_ script: UserScript) -> some View {
        Menu {
            Button {
                runNow(script)
            } label: { Label("Run now", systemImage: "play.fill") }
                .disabled(running.contains(script.id))
            Button {
                Task { await model.setEnabled(script, !script.enabled); await model.load() }
            } label: {
                Label(script.enabled ? "Pause schedule" : "Resume schedule",
                      systemImage: script.enabled ? "pause.fill" : "play.circle")
            }
        } label: {
            if running.contains(script.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle").foregroundStyle(BBTheme.Color.accent)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
            Text(value).font(.footnote.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
        }
    }
}
