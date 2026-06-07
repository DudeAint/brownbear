//
//  DashboardViewModel.swift
//  BrownBear
//
//  The dashboard's observable state. It reads the SAME shared stores the engine and background
//  scheduler use (BrownBearServices), so toggles/edits take effect live, and publishes to SwiftUI.
//

import Foundation
import SwiftUI

/// The Logs tab filter — All, errors/warnings only, userscript output, or page/iframe console.
enum LogFilter: String, CaseIterable, Identifiable {
    case all, errors, userscripts, page
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .errors: return "Errors"
        case .userscripts: return "Userscripts"
        case .page: return "Page"
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {

    @Published private(set) var scripts: [UserScript] = []
    @Published private(set) var recentLogs: [LogEntry] = []
    @Published var logFilter: LogFilter = .all
    @Published var scriptSearch = ""
    @Published var logSearch = ""
    @Published private(set) var scheduleStates: [String: ScheduleState] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var updateMessage: String?
    @Published private(set) var isCheckingUpdates = false

    /// Installed scripts narrowed by the search field (name + match/include/crontab rules), so a
    /// power user with dozens of scripts can find one without scrolling the whole store-ordered list.
    var filteredScripts: [UserScript] {
        let query = scriptSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scripts }
        return scripts.filter { script in
            if script.displayName.lowercased().contains(query) { return true }
            let rules = script.metadata.matches + script.metadata.includes + script.metadata.crontabs
            return rules.contains { $0.lowercased().contains(query) }
        }
    }

    /// `recentLogs` narrowed by the active `logFilter` and the search text (message + script name).
    var filteredLogs: [LogEntry] {
        var entries: [LogEntry]
        switch logFilter {
        case .all: entries = recentLogs
        case .errors: entries = recentLogs.filter { $0.level == .error || $0.level == .warn }
        case .userscripts: entries = recentLogs.filter { $0.source == .userscript }
        case .page: entries = recentLogs.filter { $0.source == .page || $0.source == .iframe }
        }
        let query = logSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.message.lowercased().contains(query)
                || (entry.scriptName?.lowercased().contains(query) ?? false)
        }
    }

    private var scriptStore: ScriptStore { BrownBearServices.shared.scriptStore }
    private var logStore: LogStore { BrownBearServices.shared.logStore }
    private var scheduleStore: ScheduleStateStore { BrownBearServices.shared.scheduleStore }

    // MARK: - Derived

    var enabledCount: Int { scripts.filter(\.enabled).count }
    var backgroundScripts: [UserScript] { scripts.filter { $0.metadata.runsInBackground } }

    func scheduleState(for script: UserScript) -> ScheduleState? {
        scheduleStates[script.id.uuidString]
    }

    /// Next scheduled fire for a background script, computed from its crontabs.
    func nextFire(for script: UserScript, after date: Date = Date()) -> Date? {
        let candidates = script.metadata.crontabs.compactMap { CrontabSchedule.parse($0)?.nextFireDate(after: date) }
        return candidates.min()
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let loaded = await scriptStore.all()
        let logs = await logStore.recent(limit: 300)
        var states: [String: ScheduleState] = [:]
        for script in loaded where script.metadata.runsInBackground {
            states[script.id.uuidString] = await scheduleStore.state(for: script.id)
        }
        self.scripts = loaded
        self.recentLogs = logs
        self.scheduleStates = states
    }

    func logs(for scriptID: UUID) async -> [LogEntry] {
        await logStore.entries(forScript: scriptID, limit: 300)
    }

    // MARK: - Mutations

    func setEnabled(_ script: UserScript, _ enabled: Bool) async {
        // Optimistically flip the local row so the toggle feels instant and rapid taps don't
        // flip-flop while a full reload is in flight.
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index].enabled = enabled
        }
        await scriptStore.setEnabled(id: script.id, enabled)
    }

    /// Apply per-script overrides (injection timing/context, auto-update opt-out). Optimistically
    /// updates the local row so the picker reflects the change immediately, then persists.
    func setOverrides(_ script: UserScript, _ overrides: ScriptOverrides) async {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index].overrides = overrides.isEmpty ? nil : overrides
        }
        _ = await scriptStore.setOverrides(id: script.id, overrides)
    }

    /// Manually check a single script for an update. Reloads the library if it was updated so the
    /// detail view shows the new version, and returns the outcome for the caller to surface.
    func checkForUpdate(_ script: UserScript) async -> ScriptUpdateService.UpdateOutcome {
        let outcome = await ScriptUpdateService().checkForUpdate(script)
        if case .updated = outcome { await load() }
        return outcome
    }

    func delete(_ script: UserScript) async {
        await scriptStore.remove(id: script.id)
        await BrownBearServices.shared.valueStore.clear(scriptID: script.id)
        await scheduleStore.remove(scriptID: script.id)
        await logStore.clear(scriptID: script.id)
        await load()
    }

    /// Install a new script from source. Returns the stored record on success.
    @discardableResult
    func install(source: String) async -> UserScript? {
        do {
            let script = try await scriptStore.add(source: source)
            await load()
            return script
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Save edits to an existing script's source.
    @discardableResult
    func save(scriptID: UUID, source: String) async -> Bool {
        do {
            _ = try await scriptStore.updateSource(id: scriptID, source: source)
            await load()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func clearAllLogs() async {
        await logStore.clear()
        await load()
    }

    /// Check installed scripts for newer @versions and re-install any that have one. `auto` is the
    /// silent on-open pass: it respects the Settings toggle and a ~6h debounce, and stays quiet unless
    /// something actually updated. A manual check always runs and always reports a result.
    func checkForScriptUpdates(auto: Bool) async {
        if auto {
            guard AppSettings.autoUpdateScripts else { return }
            if let last = AppSettings.lastScriptUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        }
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        AppSettings.lastScriptUpdateCheck = Date()
        // The automatic pass respects per-script opt-out; a manual "check all" checks everything.
        let updated = await ScriptUpdateService().checkForUpdates(respectOptOut: auto)
        if !updated.isEmpty {
            await load()
            updateMessage = updated.count == 1 ? "Updated “\(updated[0])”." : "Updated \(updated.count) scripts."
        } else if !auto {
            updateMessage = "All scripts are up to date."
        }
    }
}

// MARK: - Formatting helpers

enum BBFormat {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
