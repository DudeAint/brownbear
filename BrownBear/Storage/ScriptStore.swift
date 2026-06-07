//
//  ScriptStore.swift
//  BrownBear
//
//  The durable collection of installed userscripts. An actor so the browser (main thread), the
//  message router (handling bridge calls), and — later — the background scheduler can all read
//  and mutate it without races. Module 2/3 persist to a JSON file in Application Support; the
//  Core Data migration for logs/schedules arrives with Module 4.
//

import Foundation

actor ScriptStore {

    private var scripts: [UserScript] = []
    private var didLoad = false
    private let fileURL: URL
    private let parser = ScriptMetadataParser()

    /// - Parameter fileURL: override for tests; defaults to Application Support.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/scripts.json")
        }
    }

    // MARK: - Reads

    /// All scripts, in install order.
    func all() async -> [UserScript] {
        loadIfNeeded()
        return scripts
    }

    /// All enabled scripts.
    func enabledScripts() async -> [UserScript] {
        await all().filter(\.enabled)
    }

    func script(for id: UUID) async -> UserScript? {
        loadIfNeeded()
        return scripts.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Parse and install a script from raw source. Returns the stored record.
    /// - Throws: `BrownBearError.metadataParseFailed` if the source is invalid.
    @discardableResult
    func add(source: String, enabled: Bool = true) async throws -> UserScript {
        loadIfNeeded()
        let script = try UserScript.make(from: source, enabled: enabled, parser: parser)
        scripts.append(script)
        persist()
        return script
    }

    /// Replace an existing script's source (re-parsing metadata).
    /// - Throws: `BrownBearError.unknownTab`-style not-found, or parse failure.
    @discardableResult
    func updateSource(id: UUID, source: String) async throws -> UserScript {
        loadIfNeeded()
        guard let index = scripts.firstIndex(where: { $0.id == id }) else {
            throw BrownBearError.metadataParseFailed("script \(id) not found")
        }
        var script = scripts[index]
        try script.updateSource(source, parser: parser)
        scripts[index] = script
        persist()
        return script
    }

    func setEnabled(id: UUID, _ enabled: Bool) async {
        loadIfNeeded()
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].enabled = enabled
        scripts[index].updatedAt = Date()
        persist()
    }

    /// Apply per-script overrides (injection timing/context, auto-update opt-out). The struct is
    /// pruned back to `nil` when empty so untouched scripts stay clean in storage. Returns the
    /// updated record, or `nil` if no script has that id.
    @discardableResult
    func setOverrides(id: UUID, _ overrides: ScriptOverrides) async -> UserScript? {
        loadIfNeeded()
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return nil }
        scripts[index].overrides = overrides.isEmpty ? nil : overrides
        scripts[index].updatedAt = Date()
        persist()
        return scripts[index]
    }

    func remove(id: UUID) async {
        loadIfNeeded()
        scripts.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder.brownBear.decode([UserScript].self, from: data) {
            scripts = decoded
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(scripts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure must not crash; the in-memory set stays authoritative for
            // this session. Surfaced to logs in Module 4.
        }
    }
}

// MARK: - Shared coders

extension JSONEncoder {
    static let brownBear: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let brownBear: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
