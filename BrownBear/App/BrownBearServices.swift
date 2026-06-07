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
    let bookmarkStore = BookmarkStore()
    let historyStore = HistoryStore()
    let siteSettingsStore = SiteSettingsStore()
    /// Per-script user grants for hosts NOT in a script's `@connect` (ScriptCat-style allow-always).
    let connectGrantStore = ConnectGrantStore()
    let backgroundScheduler: BrownBearBackgroundScheduler

    // Module 6 — browser extensions.
    let webExtensionStore = WebExtensionStore()
    let webExtensionStorage = WebExtensionStorage()
    /// Module 6 Phase 3 — chrome.action badge/title/icon/popup state, shared across content/popup/bg
    /// and surfaced in the browser's overflow menu.
    let webExtensionActionState = WebExtensionActionState()
    /// Module 6 Phase 2 — headless background service workers + the content↔background message bus.
    let webExtensionRuntime: WebExtensionRuntime

    private init() {
        backgroundScheduler = BrownBearBackgroundScheduler(scriptStore: scriptStore,
                                                           valueStore: valueStore,
                                                           logStore: logStore,
                                                           scheduleStore: scheduleStore)
        // Constructed with explicit dependencies — `BrownBearServices.shared` isn't assigned yet
        // while this initializer runs, so the runtime's defaulted args would recurse.
        webExtensionRuntime = WebExtensionRuntime(store: webExtensionStore,
                                                  storage: webExtensionStorage,
                                                  logStore: logStore)
    }
}
