//
//  ScheduleStateStore.swift
//  BrownBear
//
//  Tracks, per background script, when it last ran and when it's next due — the durable state
//  the crontab scheduler needs so it fires each schedule once (and survives app restarts /
//  background relaunches). An actor; JSON-persisted.
//

import Foundation

struct ScheduleState: Codable, Equatable {
    var lastFire: Date?
    var nextFire: Date?
}

actor ScheduleStateStore {

    /// Keyed by script UUID string so the persisted JSON uses readable string keys.
    private var states: [String: ScheduleState] = [:]
    private var didLoad = false
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/schedules.json")
        }
    }

    func state(for scriptID: UUID) -> ScheduleState {
        loadIfNeeded()
        return states[scriptID.uuidString] ?? ScheduleState()
    }

    func lastFire(for scriptID: UUID) -> Date? {
        state(for: scriptID).lastFire
    }

    func record(scriptID: UUID, lastFire: Date, nextFire: Date?) {
        loadIfNeeded()
        states[scriptID.uuidString] = ScheduleState(lastFire: lastFire, nextFire: nextFire)
        persist()
    }

    func setNextFire(scriptID: UUID, _ nextFire: Date?) {
        loadIfNeeded()
        var state = states[scriptID.uuidString] ?? ScheduleState()
        state.nextFire = nextFire
        states[scriptID.uuidString] = state
        persist()
    }

    /// The earliest upcoming fire across all scripts, used to schedule the next BG wake.
    func earliestNextFire() -> Date? {
        loadIfNeeded()
        return states.values.compactMap(\.nextFire).min()
    }

    func remove(scriptID: UUID) {
        loadIfNeeded()
        states.removeValue(forKey: scriptID.uuidString)
        persist()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        // Must decode with the SAME key type persist() encoded (String) — Foundation encodes a
        // [String: V] dictionary as a JSON object but a [UUID: V] as an array, so a mismatch
        // silently fails and the schedule state never reloads after a background cold-start.
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.brownBear.decode([String: ScheduleState].self, from: data) else { return }
        states = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(states)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort.
        }
    }
}
