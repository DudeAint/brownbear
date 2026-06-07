//
//  ConnectGrantStore.swift
//  BrownBear
//
//  Per-script user grants for hosts that are NOT in a userscript's `@connect` allowlist — the
//  ScriptCat "allow always for this script" decision. When a script's GM_xmlhttpRequest targets an
//  undeclared host, BrownBear prompts; tapping Allow records `(scriptID → host)` here so the same
//  host proceeds silently next time. This is purely additive to `@connect`: it never weakens the
//  fail-closed default (a host is permitted only if declared OR explicitly granted here).
//
//  An actor because the sandbox message router (per bridge call) reads/writes it. JSON-backed.
//

import Foundation

actor ConnectGrantStore {

    /// scriptID → set of user-granted hosts (lowercased).
    private var grants: [UUID: Set<String>] = [:]
    private var didLoad = false
    private let fileURL: URL

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
            self.fileURL = base.appendingPathComponent("BrownBear/connect-grants.json")
        }
    }

    // MARK: - Reads

    /// True if the user has granted `host` (exactly, or as a parent domain) to this script.
    func isAllowed(scriptID: UUID, host: String) -> Bool {
        loadIfNeeded()
        let host = host.lowercased()
        guard let hosts = grants[scriptID], !hosts.isEmpty else { return false }
        if hosts.contains(host) { return true }
        // A grant for "example.com" also covers "api.example.com" (the host the user saw or a sub).
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The hosts the user has granted to this script, sorted for stable display.
    func allowedHosts(scriptID: UUID) -> [String] {
        loadIfNeeded()
        return (grants[scriptID].map(Array.init) ?? []).sorted()
    }

    // MARK: - Mutations

    /// Persist an always-allow grant of `host` for this script.
    func allow(scriptID: UUID, host: String) {
        loadIfNeeded()
        let host = host.lowercased()
        guard !host.isEmpty else { return }
        grants[scriptID, default: []].insert(host)
        persist()
    }

    /// Revoke a previously-granted host (the dashboard's "Allowed by you" row).
    func revoke(scriptID: UUID, host: String) {
        loadIfNeeded()
        grants[scriptID]?.remove(host.lowercased())
        if grants[scriptID]?.isEmpty == true { grants[scriptID] = nil }   // prune empty
        persist()
    }

    /// Drop every grant for a script (called when the script is deleted).
    func clear(scriptID: UUID) {
        loadIfNeeded()
        guard grants[scriptID] != nil else { return }
        grants[scriptID] = nil
        persist()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        for (key, hosts) in decoded {
            guard let id = UUID(uuidString: key) else { continue }
            grants[id] = Set(hosts.map { $0.lowercased() })
        }
    }

    private func persist() {
        // Encode UUID keys as strings (JSON object keys must be strings).
        let encodable = Dictionary(uniqueKeysWithValues: grants.map { ($0.key.uuidString, Array($0.value).sorted()) })
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(encodable)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure must not crash; the in-memory grants stay authoritative this session.
        }
    }
}
