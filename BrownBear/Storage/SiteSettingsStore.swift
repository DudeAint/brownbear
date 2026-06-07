//
//  SiteSettingsStore.swift
//  BrownBear
//
//  Durable per-host site preferences, persisted as JSON. An actor because the per-site sheet (the
//  omnibox lock/Shields surface) writes it and every navigation reads it to apply desktop-UA, zoom,
//  blocking, and JS choices before/after load. Keyed by a normalized host (lowercased, "www."
//  stripped) — pragmatic per-host scoping like Safari/Orion, without bundling a public-suffix list.
//  Entries that pin nothing are pruned so the file only holds real overrides.
//

import Foundation

actor SiteSettingsStore {

    private var byHost: [String: SiteSettings] = [:]
    private var didLoad = false
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("BrownBear/site-settings.json")
        }
    }

    // MARK: - Reads

    /// Stored settings for a URL's host, or `.none` if this host has no overrides.
    func settings(for url: URL) -> SiteSettings {
        loadIfNeeded()
        guard let host = Self.key(for: url) else { return .none }
        return byHost[host] ?? .none
    }

    /// Every host with a stored override, alphabetized — for a "Site settings" management list.
    func allHosts() -> [(host: String, settings: SiteSettings)] {
        loadIfNeeded()
        return byHost
            .sorted { $0.key < $1.key }
            .map { (host: $0.key, settings: $0.value) }
    }

    // MARK: - Mutations

    /// Apply a mutation to a host's settings, then prune the entry if it ends up pinning nothing.
    func update(for url: URL, _ mutate: (inout SiteSettings) -> Void) {
        loadIfNeeded()
        guard let host = Self.key(for: url) else { return }
        var current = byHost[host] ?? .none
        mutate(&current)
        if current.isEmpty {
            byHost.removeValue(forKey: host)
        } else {
            byHost[host] = current
        }
        persist()
    }

    func setDesktopUA(_ value: Bool?, for url: URL) {
        update(for: url) { $0.desktopUA = value }
    }

    func setZoom(_ value: Double?, for url: URL) {
        update(for: url) { $0.zoom = value }
    }

    func setBlockContent(_ value: Bool?, for url: URL) {
        update(for: url) { $0.blockContent = value }
    }

    func setAllowJavaScript(_ value: Bool?, for url: URL) {
        update(for: url) { $0.allowJavaScript = value }
    }

    /// Forget all overrides for a host.
    func clear(for url: URL) {
        loadIfNeeded()
        guard let host = Self.key(for: url) else { return }
        byHost.removeValue(forKey: host)
        persist()
    }

    /// Forget every site's overrides (part of "Clear browsing data").
    func clearAll() {
        loadIfNeeded()
        byHost.removeAll()
        persist()
    }

    // MARK: - Identity

    /// Normalize a URL to a host key: lowercased, "www." stripped. Returns nil for URLs without a
    /// host (about:blank, data:, file: with no authority) which have no meaningful per-site scope.
    private static func key(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.brownBear.decode([String: SiteSettings].self, from: data) else { return }
        byHost = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(byHost)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort; the in-memory map stays authoritative for the session.
        }
    }
}
