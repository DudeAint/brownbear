//
//  GMValueChange.swift
//  BrownBear
//
//  Transport for a GM value change made OUTSIDE a live page — by the background/@crontab runner or the
//  dashboard value editor — so the FOREGROUND injection engine can push it into any open page running
//  that script (live GM_getValue / GM_addValueChangeListener), Tampermonkey/Violentmonkey cross-context
//  parity. Posted as a notification rather than called directly because the InjectionOrchestrator is
//  owned per browser scene (there is no orchestrator to reach when the background runner executes with
//  the app closed) — so this is a no-op exactly when there is no page to update.
//

import Foundation

/// One GM value mutation: the key plus its old/new JSON-encoded value strings. `new == nil` is a delete.
struct GMValueChange: Sendable {
    let key: String
    let old: String?
    let new: String?
}

/// A batch of external GM value changes for one script, carried as the `object` of
/// `.brownBearGMValueChangedExternally`.
struct GMValueChangeBroadcast: Sendable {
    let scriptID: UUID
    let changes: [GMValueChange]
}

extension Notification.Name {
    /// Posted (object: `GMValueChangeBroadcast`) when a background or dashboard write changes a script's
    /// GM values. InjectionOrchestrator (foreground) observes it and broadcasts into open pages; nothing
    /// observes it when the app is backgrounded, so there is no work to do and no cost.
    static let brownBearGMValueChangedExternally = Notification.Name("brownBearGMValueChangedExternally")
}
