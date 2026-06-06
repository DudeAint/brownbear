//
//  LogStore.swift
//  BrownBear
//
//  Durable, bounded log of script execution output. An actor (background scheduler + UI both
//  touch it). Kept as a capped ring of the most recent entries so it can't grow without bound;
//  the dashboard reads it, the headless runner and bridge write to it.
//

import Foundation

actor LogStore {

    /// Maximum retained entries; older ones are evicted (most-recent-wins).
    private let capacity: Int
    private var entries: [LogEntry] = []
    private var didLoad = false
    private let fileURL: URL

    init(fileURL: URL? = nil, capacity: Int = 1000) {
        self.capacity = capacity
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/logs.json")
        }
    }

    // MARK: - Writes

    func append(_ entry: LogEntry) {
        loadIfNeeded()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist()
    }

    func append(_ newEntries: [LogEntry]) {
        guard !newEntries.isEmpty else { return }
        loadIfNeeded()
        entries.append(contentsOf: newEntries)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist()
    }

    // MARK: - Reads

    /// Most recent entries first, up to `limit`.
    func recent(limit: Int = 200) -> [LogEntry] {
        loadIfNeeded()
        return Array(entries.suffix(limit).reversed())
    }

    /// Most recent entries for one script, newest first.
    func entries(forScript scriptID: UUID, limit: Int = 200) -> [LogEntry] {
        loadIfNeeded()
        return Array(entries.filter { $0.scriptID == scriptID }.suffix(limit).reversed())
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    func clear(scriptID: UUID) {
        loadIfNeeded()
        entries.removeAll { $0.scriptID == scriptID }
        persist()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.brownBear.decode([LogEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort; a logging failure must never crash a run.
        }
    }
}
