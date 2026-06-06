//
//  BrownBearBackgroundScheduler.swift
//  BrownBear
//
//  Replicates ScriptCat's background magic within iOS's rules. It registers two BGTaskScheduler
//  tasks — an app-refresh task (short, frequent) and a processing task (longer, network) — and on
//  each wake runs every background/@crontab script that has come due since its last run, headless,
//  within the OS-granted budget, then logs results and reschedules.
//
//  iOS background execution is best-effort and budgeted: @crontab is a TARGET schedule, not a hard
//  real-time guarantee. We catch up missed fires (run-once-when-due) rather than firing per minute.
//

import BackgroundTasks
import Foundation

final class BrownBearBackgroundScheduler: @unchecked Sendable {

    static let refreshTaskID = "com.brownbear.refresh"
    static let processingTaskID = "com.brownbear.processing"

    private let scriptStore: ScriptStore
    private let scheduleStore: ScheduleStateStore
    private let logStore: LogStore
    private let runner: HeadlessScriptRunner

    init(scriptStore: ScriptStore, valueStore: GMValueStore, logStore: LogStore, scheduleStore: ScheduleStateStore) {
        self.scriptStore = scriptStore
        self.scheduleStore = scheduleStore
        self.logStore = logStore
        self.runner = HeadlessScriptRunner(valueStore: valueStore)
    }

    // MARK: - Registration (call once from didFinishLaunching, before launch completes)

    func registerTaskHandlers() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { [weak self] task in
            self?.handle(task, budget: 25)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskID, using: nil) { [weak self] task in
            self?.handle(task, budget: 110)
        }
    }

    /// Submit the next wake requests. Safe to call repeatedly (each replaces the pending one).
    func scheduleNextRun() {
        Task {
            let earliest = await self.scheduleStore.earliestNextFire()
            self.submitAppRefresh(earliest: earliest)
            self.submitProcessing(earliest: earliest)
        }
    }

    private func submitAppRefresh(earliest: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        // App refresh can't be sooner than ~15 minutes; honor the schedule if it's later.
        request.earliestBeginDate = max(Date().addingTimeInterval(15 * 60), earliest ?? .distantPast)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func submitProcessing(earliest: Date?) {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliest ?? Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Task handling

    private func handle(_ task: BGTask, budget: TimeInterval) {
        // Stop a few seconds before the OS budget so we finish and call setTaskCompleted in time;
        // overrunning gets the app throttled for future background scheduling.
        let deadline = Date().addingTimeInterval(max(1, budget - 3))

        // Ensure setTaskCompleted runs exactly once, from whichever path wins (normal or expiry).
        let completionLock = NSLock()
        var completed = false
        func complete(_ success: Bool) {
            completionLock.lock(); defer { completionLock.unlock() }
            guard !completed else { return }
            completed = true
            task.setTaskCompleted(success: success)
        }

        // Assign the expiration handler BEFORE starting work so there is no window where the OS
        // could expire the task with no handler installed.
        var work: Task<Void, Never>?
        task.expirationHandler = {
            work?.cancel()
            complete(false)
        }
        work = Task {
            await self.runDueScripts(deadline: deadline)
            self.scheduleNextRun()
            complete(!Task.isCancelled)
        }
    }

    // MARK: - The execution loop (also the unit-testable core)

    /// Run every enabled background script that is due, until `deadline`. Returns how many ran.
    @discardableResult
    func runDueScripts(deadline: Date, now: Date = Date()) async -> Int {
        let scripts = await scriptStore.enabledScripts().filter { $0.metadata.runsInBackground }
        var ranCount = 0

        for script in scripts {
            if Task.isCancelled || Date() >= deadline { break }
            let lastFire = await scheduleStore.lastFire(for: script.id)
            guard isDue(script: script, now: now, lastFire: lastFire) else { continue }

            let fireTime = Date()
            let (outcome, logs) = await runner.run(script, deadline: deadline)
            await logStore.append(logs)
            await logStore.append([resultLog(for: script, outcome: outcome)])

            let next = nextFireDate(for: script, after: fireTime)
            await scheduleStore.record(scriptID: script.id, lastFire: fireTime, nextFire: next)
            ranCount += 1
        }
        return ranCount
    }

    // MARK: - Scheduling math

    func isDue(script: UserScript, now: Date, lastFire: Date?) -> Bool {
        // A pure @background script (no crontab) runs once per enablement.
        if script.metadata.crontabs.isEmpty {
            return script.metadata.isBackground && lastFire == nil
        }
        return script.metadata.crontabs.contains { expression in
            CrontabSchedule.parse(expression)?.isDue(now: now, lastFire: lastFire) ?? false
        }
    }

    func nextFireDate(for script: UserScript, after date: Date) -> Date? {
        let candidates = script.metadata.crontabs.compactMap { expression -> Date? in
            CrontabSchedule.parse(expression)?.nextFireDate(after: date)
        }
        return candidates.min()
    }

    private func resultLog(for script: UserScript, outcome: HeadlessRunOutcome) -> LogEntry {
        if let error = outcome.error {
            return LogEntry(scriptID: script.id, scriptName: script.metadata.name, level: .error,
                            message: "background run failed: \(error)", context: .background)
        }
        return LogEntry(scriptID: script.id, scriptName: script.metadata.name, level: .info,
                        message: "background run completed", context: .background)
    }
}
