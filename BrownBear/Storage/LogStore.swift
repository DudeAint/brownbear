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
    /// Coalesces bursty appends into a single trailing-edge disk write, so a chatty (or hostile)
    /// writer can't force a full-file re-encode + atomic write per line. In-memory reads
    /// (`recent`/`entries(forScript:)`) are unaffected — they always see the latest `entries`.
    private var flushTask: Task<Void, Never>?

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
        scheduleFlush()
    }

    func append(_ newEntries: [LogEntry]) {
        guard !newEntries.isEmpty else { return }
        loadIfNeeded()
        entries.append(contentsOf: newEntries)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        scheduleFlush()
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
        flushTask?.cancel()
        flushTask = nil
        entries.removeAll()
        persist()
    }

    func clear(scriptID: UUID) {
        loadIfNeeded()
        entries.removeAll { $0.scriptID == scriptID }
        persist()
    }

    // MARK: - Persistence

    /// Mark dirty and persist on a trailing-edge timer, coalescing a burst of appends into one write.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.performFlush()
        }
    }

    private func performFlush() {
        flushTask = nil
        persist()
    }

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
