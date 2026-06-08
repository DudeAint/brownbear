//
//  WebExtensionManagementInfo.swift
//  BrownBear
//
//  Pure logic behind chrome.management and chrome.permissions. `chrome.management` describes the
//  installed extension set as Chrome's `ExtensionInfo` records; `chrome.permissions` reconciles a
//  requested permission set against what the manifest declares (required + optional) plus what the
//  user has granted at runtime. Both are deterministic mappings over the stored model, so they live
//  here, away from the actor/MainActor plumbing, and are unit-tested directly.
//

import Foundation

/// chrome.management ExtensionInfo + chrome.permissions reconciliation, derived from a stored
/// extension and its parsed manifest. No I/O, no concurrency — just shape mapping and set logic.
enum WebExtensionManagementInfo {

    /// Build a chrome.management `ExtensionInfo` for one extension. `chrome-extension://` URLs are
    /// minted for the icons so a management UI can render them through the scheme handler. iOS has no
    /// notion of disabling-by-policy, app vs. extension, or update URLs, so those are reported with
    /// Chrome's defaults (extension type, "normal" install, always may-disable).
    static func extensionInfo(for ext: WebExtension) -> [String: Any] {
        let manifest = ext.manifest
        var info: [String: Any] = [
            "id": ext.id,
            // displayName/displayDescription resolve `__MSG_*__` i18n placeholders (Chrome resolves
            // these before exposing them via chrome.management); the raw manifest fields can be tokens.
            "name": ext.displayName,
            "shortName": ext.displayName,
            "description": ext.displayDescription ?? "",
            "version": manifest?.version ?? "",
            "mayDisable": true,
            "enabled": ext.enabled,
            "type": "extension",
            "installType": "normal",
            "isApp": false,
            "offlineEnabled": false,
            "optionsUrl": optionsURL(for: ext),
            "homepageUrl": "",
            "updateUrl": "",
            "hostPermissions": manifest?.hostPermissions ?? [],
            "permissions": manifest?.permissions ?? [],
            "icons": iconInfos(for: ext)
        ]
        // `disabledReason` is present in Chrome only for disabled extensions; iOS only ever disables
        // by user action, so report that reason rather than omitting the field for a disabled one.
        if !ext.enabled { info["disabledReason"] = "unknown" }
        return info
    }

    /// management.getAll — one ExtensionInfo per installed extension, id-sorted for stable output.
    static func allExtensionInfos(_ exts: [WebExtension]) -> [[String: Any]] {
        exts.sorted { $0.id < $1.id }.map(extensionInfo)
    }

    /// The IconInfo array (`{ size, url }`) for an extension, sorted ascending by size. Sizes are the
    /// manifest icon keys; a bare/sizeless icon (stored under "0") is reported with size 0.
    static func iconInfos(for ext: WebExtension) -> [[String: Any]] {
        guard let icons = ext.manifest?.icons, !icons.isEmpty else { return [] }
        return icons
            .map { (size: Int($0.key) ?? 0, path: $0.value) }
            .sorted { $0.size < $1.size }
            .map { ["size": $0.size, "url": resourceURL(base: ext.baseURLString, path: $0.path)] }
    }

    /// management.getSelf's optionsUrl / ExtensionInfo.optionsUrl: a chrome-extension URL to the
    /// options page, or "" when the extension declares none (Chrome's value for that case).
    static func optionsURL(for ext: WebExtension) -> String {
        guard let page = ext.manifest?.optionsPage, !page.isEmpty else { return "" }
        return resourceURL(base: ext.baseURLString, path: page)
    }

    private static func resourceURL(base: String, path: String) -> String {
        base + (path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    // MARK: - chrome.permissions

    /// A normalized permissions request/query: API permission names plus host match-pattern origins.
    /// chrome.permissions takes/returns `{ permissions: [...], origins: [...] }`; we split them so the
    /// two are compared against the right manifest field (permissions vs. host permissions).
    struct PermissionSet: Equatable {
        var permissions: Set<String>
        var origins: Set<String>

        init(permissions: [String] = [], origins: [String] = []) {
            self.permissions = Set(permissions)
            self.origins = Set(origins)
        }

        /// Parse the `{ permissions, origins }` shape JS hands the bridge, tolerating missing keys.
        init(payload: [String: Any]) {
            self.permissions = Set((payload["permissions"] as? [String]) ?? [])
            self.origins = Set((payload["origins"] as? [String]) ?? [])
        }

        var isEmpty: Bool { permissions.isEmpty && origins.isEmpty }

        /// The chrome.permissions.Permissions object (sorted for stable output).
        var dictionary: [String: Any] {
            ["permissions": permissions.sorted(), "origins": origins.sorted()]
        }
    }

    /// Everything a manifest could ever surface to chrome.permissions: required API permissions,
    /// optional API permissions, and all host patterns (host_permissions + content-script matches).
    static func declaredPermissions(for manifest: WebExtensionManifest?) -> PermissionSet {
        guard let manifest else { return PermissionSet() }
        let perms = manifest.permissions + manifest.optionalPermissions
        return PermissionSet(permissions: perms, origins: manifest.effectiveHostPatterns)
    }

    /// The required (non-optional) manifest permissions, which a script always holds and may not
    /// remove via chrome.permissions.remove (Chrome rejects removing a required permission).
    static func requiredPermissions(for manifest: WebExtensionManifest?) -> PermissionSet {
        guard let manifest else { return PermissionSet() }
        return PermissionSet(permissions: manifest.permissions, origins: manifest.hostPermissions)
    }

    /// The optional permissions the manifest declares — the only ones chrome.permissions.request may
    /// grant (Chrome rejects requesting a permission not listed in `optional_permissions`).
    static func optionalPermissions(for manifest: WebExtensionManifest?) -> PermissionSet {
        guard let manifest else { return PermissionSet() }
        // Optional host patterns: anything matchable that isn't a required host permission.
        let requiredHosts = Set(manifest.hostPermissions)
        let optionalHosts = Set(manifest.effectiveHostPatterns).subtracting(requiredHosts)
        return PermissionSet(permissions: manifest.optionalPermissions, origins: Array(optionalHosts))
    }

    /// The currently-held permission set: required-by-manifest plus whatever the user has granted at
    /// runtime via chrome.permissions.request.
    static func effective(manifest: WebExtensionManifest?, granted: PermissionSet) -> PermissionSet {
        var set = requiredPermissions(for: manifest)
        set.permissions.formUnion(granted.permissions)
        set.origins.formUnion(granted.origins)
        return set
    }

    /// chrome.permissions.contains — true only if EVERY requested permission/origin is currently held
    /// (required-by-manifest or runtime-granted). An empty request trivially contains.
    static func contains(_ requested: PermissionSet,
                         manifest: WebExtensionManifest?,
                         granted: PermissionSet) -> Bool {
        let held = effective(manifest: manifest, granted: granted)
        return requested.permissions.isSubset(of: held.permissions)
            && requested.origins.isSubset(of: held.origins)
    }

    /// chrome.permissions.request resolution. Returns the set of permissions to NEWLY record as
    /// granted, or nil if the request must be rejected (asked for something the manifest never
    /// declared as required OR optional — Chrome throws/returns false for that). Already-held
    /// permissions resolve to an empty "to grant" set (request still returns true).
    static func resolveRequest(_ requested: PermissionSet,
                               manifest: WebExtensionManifest?) -> PermissionSet? {
        let declared = declaredPermissions(for: manifest)
        // Reject if anything requested was never declared anywhere in the manifest.
        guard requested.permissions.isSubset(of: declared.permissions),
              requested.origins.isSubset(of: declared.origins) else { return nil }
        return requested
    }

    /// chrome.permissions.remove — the runtime-granted set after removing `requested`, or nil if the
    /// request tries to remove a REQUIRED (manifest-mandated) permission, which Chrome rejects.
    static func resolveRemove(_ requested: PermissionSet,
                              manifest: WebExtensionManifest?,
                              granted: PermissionSet) -> PermissionSet? {
        let required = requiredPermissions(for: manifest)
        guard requested.permissions.isDisjoint(with: required.permissions),
              requested.origins.isDisjoint(with: required.origins) else { return nil }
        var remaining = granted
        remaining.permissions.subtract(requested.permissions)
        remaining.origins.subtract(requested.origins)
        return remaining
    }
}
