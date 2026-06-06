//
//  BrownBearServices.swift
//  BrownBear
//
//  The process-wide service container. The foreground engine (InjectionOrchestrator) and the
//  background scheduler must share the SAME store instances, or their in-memory caches diverge
//  and a value written on one side wouldn't be seen on the other. This holds the single shared
//  ScriptStore, GMValueStore, LogStore, ScheduleStateStore, and the background scheduler.
//

import Foundation

@MainActor
final class BrownBearServices {

    static let shared = BrownBearServices()

    let scriptStore = ScriptStore()
    let valueStore = GMValueStore()
    let logStore = LogStore()
    let scheduleStore = ScheduleStateStore()
    let backgroundScheduler: BrownBearBackgroundScheduler

    // Module 6 — browser extensions.
    let webExtensionStore = WebExtensionStore()
    let webExtensionStorage = WebExtensionStorage()

    private init() {
        backgroundScheduler = BrownBearBackgroundScheduler(scriptStore: scriptStore,
                                                           valueStore: valueStore,
                                                           logStore: logStore,
                                                           scheduleStore: scheduleStore)
    }
}
