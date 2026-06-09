//
//  WebExtensionPermissionGrants.swift
//  BrownBear
//
//  Runtime state for chrome.permissions and chrome.runtime.setUninstallURL, namespaced per extension.
//  A manifest's optional permissions are not held until a script calls chrome.permissions.request;
//  this actor records the ones the user has granted (and lets chrome.permissions.remove drop them),
//  separately from the manifest's required permissions which are always in effect. It also persists
//  the uninstall URL an extension registers so the dashboard can open it when the extension is
//  removed. Mirrors ConnectGrantStore's JSON-backed, actor-isolated pattern.
//
//  Isolation: grants are keyed by the extension's stable id, so one extension can never read or
//  mutate another's granted permissions — the same per-extension containment as storage.
//

import Foundation

actor WebExtensionPermissionGrants {

    /// extensionID → the optional permissions/origins the user has granted at runtime.
    private var grants: [String: WebExtensionManagementInfo.PermissionSet] = [:]
    /// extensionID → the uninstall URL registered via chrome.runtime.setUninstallURL.
    private var uninstallURLs: [String: String] = [:]
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
            self.fileURL = base.appendingPathComponent("BrownBear/webext-permissions.json")
        }
    }

    // MARK: - Reads

    /// The runtime-granted optional permission set for an extension (empty if none).
    func granted(extensionID: String) -> WebExtensionManagementInfo.PermissionSet {
        loadIfNeeded()
        return grants[extensionID] ?? WebExtensionManagementInfo.PermissionSet()
    }

    /// The registered uninstall URL for an extension, if any.
    func uninstallURL(extensionID: String) -> String? {
        loadIfNeeded()
        return uninstallURLs[extensionID]
    }

    // MARK: - Mutations

    /// Record a newly-granted permission set (union with anything already granted). Announces the
    /// actually-new delta so chrome.permissions.onAdded fires (Chrome parity).
    func grant(extensionID: String, _ set: WebExtensionManagementInfo.PermissionSet) {
        guard !set.isEmpty else { return }
        loadIfNeeded()
        var current = grants[extensionID] ?? WebExtensionManagementInfo.PermissionSet()
        // Only the parts not already held are "added" — re-granting a held permission fires nothing.
        let added = WebExtensionManagementInfo.PermissionSet(
            permissions: Array(set.permissions.subtracting(current.permissions)),
            origins: Array(set.origins.subtracting(current.origins)))
        current.permissions.formUnion(set.permissions)
        current.origins.formUnion(set.origins)
        grants[extensionID] = current
        persist()
        broadcastChange(extensionID: extensionID, added: added,
                        removed: WebExtensionManagementInfo.PermissionSet())
    }

    /// Replace the granted set for an extension (used by chrome.permissions.remove, which computes
    /// the remaining set). An empty result prunes the entry. Announces the old-vs-new delta so
    /// chrome.permissions.onRemoved (and onAdded, should the set ever grow here) fires.
    func setGranted(extensionID: String, _ set: WebExtensionManagementInfo.PermissionSet) {
        loadIfNeeded()
        let old = grants[extensionID] ?? WebExtensionManagementInfo.PermissionSet()
        if set.isEmpty { grants[extensionID] = nil } else { grants[extensionID] = set }
        persist()
        let removed = WebExtensionManagementInfo.PermissionSet(
            permissions: Array(old.permissions.subtracting(set.permissions)),
            origins: Array(old.origins.subtracting(set.origins)))
        let added = WebExtensionManagementInfo.PermissionSet(
            permissions: Array(set.permissions.subtracting(old.permissions)),
            origins: Array(set.origins.subtracting(old.origins)))
        broadcastChange(extensionID: extensionID, added: added, removed: removed)
    }

    /// Announce a permission-grant change so chrome.permissions.onAdded/onRemoved fire in the
    /// extension's worker + open pages. Posting from the actor is fine — NotificationCenter is
    /// thread-safe and the runtime's observer hops to the main actor (mirrors WebExtensionStorage).
    /// A purely-empty change is not posted.
    private func broadcastChange(extensionID: String,
                                 added: WebExtensionManagementInfo.PermissionSet,
                                 removed: WebExtensionManagementInfo.PermissionSet) {
        guard !added.isEmpty || !removed.isEmpty else { return }
        NotificationCenter.default.post(
            name: .brownBearExtensionPermissionsDidChange,
            object: nil,
            userInfo: ["extensionID": extensionID, "added": added.dictionary, "removed": removed.dictionary])
    }

    /// Register (or clear, with an empty string) the uninstall URL for an extension.
    func setUninstallURL(extensionID: String, url: String) {
        loadIfNeeded()
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { uninstallURLs[extensionID] = nil } else { uninstallURLs[extensionID] = trimmed }
        persist()
    }

    /// Drop all runtime state for an extension (called when it is uninstalled).
    func clear(extensionID: String) {
        loadIfNeeded()
        guard grants[extensionID] != nil || uninstallURLs[extensionID] != nil else { return }
        grants[extensionID] = nil
        uninstallURLs[extensionID] = nil
        persist()
    }

    // MARK: - Persistence

    /// On-disk shape: a per-extension record of granted permissions/origins and the uninstall URL.
    private struct Record: Codable {
        var permissions: [String]
        var origins: [String]
        var uninstallURL: String?
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        for (id, record) in decoded {
            let set = WebExtensionManagementInfo.PermissionSet(permissions: record.permissions,
                                                               origins: record.origins)
            if !set.isEmpty { grants[id] = set }
            if let url = record.uninstallURL, !url.isEmpty { uninstallURLs[id] = url }
        }
    }

    private func persist() {
        var encodable: [String: Record] = [:]
        let ids = Set(grants.keys).union(uninstallURLs.keys)
        for id in ids {
            let set = grants[id] ?? WebExtensionManagementInfo.PermissionSet()
            encodable[id] = Record(permissions: set.permissions.sorted(),
                                   origins: set.origins.sorted(),
                                   uninstallURL: uninstallURLs[id])
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(encodable)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure must not crash; the in-memory state stays authoritative this session.
        }
    }
}
