//
//  BackgroundSchedulerRunTests.swift
//  BrownBearTests
//
//  Integration coverage for the execution path that was never being invoked outside the (unreliable)
//  iOS background task: a DUE background script must actually run, produce log output, and record a
//  "last run" — the symptom the user hit ("background scripts never run / no last run"). The
//  foreground catch-up (SceneDelegate.sceneDidBecomeActive → runDueScriptsOnForeground) drives exactly
//  this `runDueScripts` loop.
//

import XCTest
@testable import BrownBear

final class BackgroundSchedulerRunTests: XCTestCase {

    func testDueBackgroundScriptRunsRecordsLastFireAndLogs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-sched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptStore = ScriptStore(fileURL: dir.appendingPathComponent("scripts.json"))
        let scheduleStore = ScheduleStateStore(fileURL: dir.appendingPathComponent("schedule.json"))
        let logStore = LogStore(fileURL: dir.appendingPathComponent("logs.json"))
        let valueStore = GMValueStore(suiteName: "brownbear.test.\(UUID().uuidString)")
        let scheduler = BrownBearBackgroundScheduler(scriptStore: scriptStore, valueStore: valueStore,
                                                     logStore: logStore, scheduleStore: scheduleStore)

        let source = """
        // ==UserScript==
        // @name        BG Once
        // @background
        // ==/UserScript==
        console.log("ran in background");
        """
        let installed = try await scriptStore.add(source: source)

        // No last-run before the catch-up runs (the reported state).
        let before = await scheduleStore.lastFire(for: installed.id)
        XCTAssertNil(before)

        let ran = await scheduler.runDueScripts(deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(ran, 1, "a due @background script must actually run")

        let after = await scheduleStore.lastFire(for: installed.id)
        XCTAssertNotNil(after, "running must record a last-run time — the reported bug")

        let logs = await logStore.entries(forScript: installed.id, limit: 50)
        XCTAssertFalse(logs.isEmpty, "the run must produce log output")

        // A once-background script is not due again — no duplicate run.
        let ranAgain = await scheduler.runDueScripts(deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(ranAgain, 0)
    }
}
