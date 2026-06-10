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

    /// Everything chrome.permissions.request may ever grant: required + optional API permissions, and the
    /// REQUESTABLE host patterns — host_permissions (already held) + optional_host_permissions. NOT
    /// content_scripts.matches: a content-script match confers no host access in Chrome and must never be
    /// escalatable to full host access via permissions.request (privilege-escalation guard, cf. #131).
    static func declaredPermissions(for manifest: WebExtensionManifest?) -> PermissionSet {
        guard let manifest else { return PermissionSet() }
        let perms = manifest.permissions + manifest.optionalPermissions
        let origins = manifest.hostPermissions + manifest.optionalHostPermissions
        return PermissionSet(permissions: perms, origins: origins)
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
        // Optional hosts are exactly the declared optional_host_permissions — NOT content-script matches
        // (those grant no host access and aren't requestable). Drop any that duplicate a required host.
        let optionalHosts = Set(manifest.optionalHostPermissions).subtracting(Set(manifest.hostPermissions))
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
            && originsCovered(requested.origins, by: held.origins)
    }

    /// chrome.permissions.request resolution. Returns the set of permissions to NEWLY record as
    /// granted, or nil if the request must be rejected (asked for something the manifest never
    /// declared as required OR optional — Chrome throws/returns false for that). Already-held
    /// permissions resolve to an empty "to grant" set (request still returns true).
    static func resolveRequest(_ requested: PermissionSet,
                               manifest: WebExtensionManifest?) -> PermissionSet? {
        let declared = declaredPermissions(for: manifest)
        // Reject if anything requested was never declared anywhere in the manifest. Origins are matched by
        // Chrome match-pattern CONTAINMENT, not exact string membership: an extension that declares a broad
        // optional_host_permissions (`<all_urls>` / `*://*/*`) and requests a single site `*://site.com/*`
        // at runtime — uBlock Origin Lite does exactly this when you raise a site's filtering mode — is a
        // valid request and must not be silently rejected.
        guard requested.permissions.isSubset(of: declared.permissions),
              originsCovered(requested.origins, by: declared.origins) else { return nil }
        return requested
    }

    /// True if every requested host match-pattern is COVERED by some declared/held host pattern, per
    /// Chrome's match-pattern containment (a broad `<all_urls>` / `*://*/*` covers a specific
    /// `*://site.com/*`; `*.foo.com` covers `foo.com` and its subdomains). Exact-string membership was the
    /// bug: a broad-optional extension requesting one origin got rejected before the consent prompt even
    /// showed. An empty request is trivially covered (nothing new to grant). Pure — unit-tested.
    static func originsCovered(_ requested: Set<String>, by declared: Set<String>) -> Bool {
        if requested.isEmpty { return true }
        let declaredPatterns = declared.compactMap(HostMatchPattern.init)
        return requested.allSatisfy { req in
            guard let r = HostMatchPattern(req) else { return false }
            return declaredPatterns.contains { $0.covers(r) }
        }
    }

    /// A parsed Chrome host match pattern (`<scheme>://<host><path>` or `<all_urls>`) with the containment
    /// test chrome.permissions needs: does a declared pattern subsume a requested one? Conservative — it
    /// never reports coverage it can't justify, so it can't widen what an extension may be granted.
    private struct HostMatchPattern {
        let isAllUrls: Bool
        let scheme: String   // lowercased; "*" or a concrete scheme
        let host: String     // lowercased; "*", "*.domain", or an exact host
        let path: String     // e.g. "/*"

        init?(_ raw: String) {
            let pattern = raw.trimmingCharacters(in: .whitespaces)
            if pattern == "<all_urls>" {
                isAllUrls = true; scheme = "*"; host = "*"; path = "/*"; return
            }
            guard let sep = pattern.range(of: "://") else { return nil }
            let scheme = pattern[pattern.startIndex..<sep.lowerBound].lowercased()
            guard !scheme.isEmpty else { return nil }
            let rest = pattern[sep.upperBound...]
            let host: Substring, path: Substring
            if let slash = rest.firstIndex(of: "/") {
                host = rest[rest.startIndex..<slash]
                path = rest[slash...]
            } else {
                host = rest; path = "/*"
            }
            guard !host.isEmpty || scheme == "file" else { return nil }
            self.isAllUrls = false
            self.scheme = scheme
            self.host = host.lowercased()
            self.path = path.isEmpty ? "/*" : String(path)
        }

        /// True if every URL `other` (a requested pattern) matches is also matched by `self` (declared).
        func covers(_ other: HostMatchPattern) -> Bool {
            if isAllUrls { return true }
            if other.isAllUrls { return false }   // only <all_urls> covers <all_urls>
            return schemeCovers(other.scheme) && hostCovers(other.host) && pathCovers(other.path)
        }

        private func schemeCovers(_ other: String) -> Bool {
            if scheme == other { return true }
            // Chrome's "*" scheme spans http/https/ws/wss; a declared "*" covers those concrete schemes.
            return scheme == "*" && ["http", "https", "ws", "wss"].contains(other)
        }

        private func hostCovers(_ other: String) -> Bool {
            if host == "*" { return true }       // "*" host covers any host
            if other == "*" { return false }     // only "*" covers "*"
            if host.hasPrefix("*.") {
                let suffix = String(host.dropFirst(2))           // "*.foo.com" → "foo.com" (+subdomains)
                if other.hasPrefix("*.") {
                    let otherSuffix = String(other.dropFirst(2))
                    return otherSuffix == suffix || otherSuffix.hasSuffix("." + suffix)
                }
                return other == suffix || other.hasSuffix("." + suffix)
            }
            return host == other                 // exact host covers only the identical host
        }

        private func pathCovers(_ other: String) -> Bool {
            if path == "/*" || path == other { return true }
            if path.hasSuffix("/*") {            // a prefix glob covers any path under it
                return other.hasPrefix(String(path.dropLast(1)))
            }
            return false
        }
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
