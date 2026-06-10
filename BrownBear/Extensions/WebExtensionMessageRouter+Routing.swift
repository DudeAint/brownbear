//
//  WebExtensionMessageRouter+Routing.swift
//  BrownBear
//
//  chrome.notifications / chrome.action / chrome.windows / chrome.management / chrome.permissions /
//  chrome.declarativeNetRequest (dynamic+session) / chrome.userScripts routing for the extension
//  message router, split out of the main file (SwiftLint file-length limit). A cross-file extension of
//  the same module reaches the router's `internal` members (store/host/cookieHost/...); the entry
//  methods route() dispatches to are `func` (internal) for exactly that reason. chrome.cookies + the
//  scripting/cookies permission gates live in WebExtensionMessageRouter+Permissions.swift.
//

import WebKit

extension WebExtensionMessageRouter {

    // chrome.cookies routing + the scripting/cookies permission gates live in
    // WebExtensionMessageRouter+Permissions.swift (file-length limit).

    // MARK: - chrome.notifications

    /// chrome.notifications — UNUserNotificationCenter-backed via the bridge host. `extensionID`
    /// (resolved from the token above) gates the manifest "notifications" permission in the manager.
    func routeNotifications(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        switch api {
        case "notifications.create":
            guard let host else { throw BrownBearError.bridgeRejected("no browser for notifications") }
            return try await host.webExtNotificationsCreate(
                extensionID: extensionID,
                notificationID: payload["notificationId"] as? String,
                options: payload["options"] as? [String: Any] ?? [:])

        case "notifications.update":
            guard let host, let id = payload["notificationId"] as? String else { return false }
            return try await host.webExtNotificationsUpdate(
                extensionID: extensionID, notificationID: id,
                options: payload["options"] as? [String: Any] ?? [:])

        case "notifications.clear":
            guard let host, let id = payload["notificationId"] as? String else { return false }
            return try await host.webExtNotificationsClear(extensionID: extensionID, notificationID: id)

        case "notifications.getAll":
            guard let host else { return [String: Bool]() }
            return try await host.webExtNotificationsGetAll(extensionID: extensionID)

        default:
            throw BrownBearError.bridgeRejected("unsupported notifications api '\(api)'")
        }
    }

    // MARK: - chrome.action / chrome.browserAction

    /// chrome.action setters/getters. State lives in the shared WebExtensionActionState (no permission
    /// needed — Chrome gates it on the manifest action entry; the token was already resolved). A
    /// tab-less property defaults to the active tab, resolved via the host. All synchronous.
    func routeAction(api: String, payload: [String: Any], extensionID: String) -> Any? {
        let state = BrownBearServices.shared.webExtensionActionState
        let tabId = (payload["tabId"] as? Int) ?? host?.webExtActionActiveTabId()
        switch api {
        case "action.setBadgeText":
            state.setBadgeText(extensionID: extensionID, tabId: tabId, text: payload["text"] as? String)
            return NSNull()
        case "action.setBadgeBackgroundColor":
            state.setBadgeColor(extensionID: extensionID, tabId: tabId, color: payload["color"] as? String)
            return NSNull()
        case "action.setBadgeTextColor":
            state.setBadgeTextColor(extensionID: extensionID, tabId: tabId, color: payload["color"] as? String)
            return NSNull()
        case "action.setTitle":
            state.setTitle(extensionID: extensionID, tabId: tabId, title: payload["title"] as? String)
            return NSNull()
        case "action.setPopup":
            state.setPopup(extensionID: extensionID, tabId: tabId, popup: payload["popup"] as? String)
            return NSNull()
        case "action.setIcon":
            state.setIcon(extensionID: extensionID, tabId: tabId, path: WebExtensionActionState.iconPath(from: payload["path"]))
            return NSNull()
        case "action.enable":
            state.setEnabled(extensionID: extensionID, tabId: tabId, true)
            return NSNull()
        case "action.disable":
            state.setEnabled(extensionID: extensionID, tabId: tabId, false)
            return NSNull()
        case "action.getBadgeText":
            return state.badgeText(extensionID: extensionID, tabId: tabId)
        case "action.getTitle":
            return state.title(extensionID: extensionID, tabId: tabId)
        case "action.getBadgeBackgroundColor":
            return state.badgeColorBytes(extensionID: extensionID, tabId: tabId)
        case "action.getBadgeTextColor":
            return state.badgeTextColorBytes(extensionID: extensionID, tabId: tabId)
        default:
            return NSNull()
        }
    }

    // MARK: - chrome.windows / chrome.management / chrome.permissions

    /// chrome.windows (single synthetic window on iOS), chrome.management (read-only), and
    /// chrome.permissions (optional-grant store) + runtime.setUninstallURL/getPlatformInfo. Split out
    /// to keep route() under the complexity limit. A valid extension token is already resolved.
    func routeWindowsManagementPermissions(api: String, payload: [String: Any],
                                                   extensionID: String) async throws -> Any? {
        switch api {
        case "windows.get", "windows.getCurrent", "windows.getLastFocused":
            guard let host else { return NSNull() }
            return host.webExtWindow(populate: (payload["populate"] as? Bool) ?? false)

        case "windows.getAll":
            guard let host else { return [] }
            return host.webExtAllWindows(populate: (payload["populate"] as? Bool) ?? false)

        case "windows.create":
            guard let host else { throw BrownBearError.bridgeRejected("no browser to open a window") }
            return host.webExtCreateWindow(url: payload["url"] as? String,
                                           active: (payload["focused"] as? Bool) ?? true,
                                           populate: (payload["populate"] as? Bool) ?? false)

        case "windows.update":
            guard let host else { return NSNull() }
            return host.webExtUpdateWindow(populate: (payload["populate"] as? Bool) ?? false)

        case "windows.remove":
            return NSNull()   // iOS has one window that can't be closed; acknowledge so JS settles.

        case "management.getAll":
            return WebExtensionManagementInfo.allExtensionInfos(await store.all())

        case "management.get":
            guard let id = payload["id"] as? String, let ext = await store.ext(for: id) else {
                throw BrownBearError.bridgeRejected("no extension with id '\(payload["id"] as? String ?? "")'")
            }
            return WebExtensionManagementInfo.extensionInfo(for: ext)

        case "management.getSelf":
            guard let ext = await store.ext(for: extensionID) else { return NSNull() }
            return WebExtensionManagementInfo.extensionInfo(for: ext)

        case "permissions.getAll":
            let manifest = await store.ext(for: extensionID)?.manifest
            let granted = await BrownBearServices.shared.webExtensionPermissionGrants.granted(extensionID: extensionID)
            return WebExtensionManagementInfo.effective(manifest: manifest, granted: granted).dictionary

        case "permissions.contains":
            let manifest = await store.ext(for: extensionID)?.manifest
            let granted = await BrownBearServices.shared.webExtensionPermissionGrants.granted(extensionID: extensionID)
            let requested = WebExtensionManagementInfo.PermissionSet(payload: payload)
            return WebExtensionManagementInfo.contains(requested, manifest: manifest, granted: granted)

        case "permissions.request":
            let ext = await store.ext(for: extensionID)
            let manifest = ext?.manifest
            let grants = BrownBearServices.shared.webExtensionPermissionGrants
            let requested = WebExtensionManagementInfo.PermissionSet(payload: payload)
            // Reject anything the manifest never declared (required or optional) — Chrome parity.
            guard let toGrant = WebExtensionManagementInfo.resolveRequest(requested, manifest: manifest) else { return false }
            // Only prompt for what is NOT already held; an already-held request resolves true silently.
            let held = await grants.granted(extensionID: extensionID)
            let effective = WebExtensionManagementInfo.effective(manifest: manifest, granted: held)
            var newlyRequested = toGrant
            newlyRequested.permissions.subtract(effective.permissions)
            newlyRequested.origins.subtract(effective.origins)
            // User consent gate (replaces the old auto-grant). Deny ⇒ resolve false, grant nothing.
            guard await WebExtensionPermissionPrompt.request(extensionName: ext?.displayName ?? extensionID,
                                                             toGrant: newlyRequested) else { return false }
            await grants.grant(extensionID: extensionID, newlyRequested)
            return true

        case "permissions.remove":
            let manifest = await store.ext(for: extensionID)?.manifest
            let grants = BrownBearServices.shared.webExtensionPermissionGrants
            let granted = await grants.granted(extensionID: extensionID)
            let requested = WebExtensionManagementInfo.PermissionSet(payload: payload)
            guard let remaining = WebExtensionManagementInfo.resolveRemove(requested, manifest: manifest, granted: granted) else {
                return false
            }
            await grants.setGranted(extensionID: extensionID, remaining)
            return true

        case "runtime.setUninstallURL":
            let url = (payload["url"] as? String) ?? ""
            await BrownBearServices.shared.webExtensionPermissionGrants.setUninstallURL(extensionID: extensionID, url: url)
            return NSNull()

        case "runtime.getPlatformInfo":
            return ["os": "ios", "arch": "arm64", "nacl_arch": "arm64"]

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    // MARK: - chrome.declarativeNetRequest (dynamic/session) + chrome.userScripts (MV3)

    /// declarativeNetRequest runtime rules + chrome.userScripts registration. Both are permission-gated
    /// (declarativeNetRequest[WithHostAccess] / userScripts). A mutation posts the change notification so
    /// the content blocker recompiles and userScripts inject on the next navigation.
    func routeDNRUserScripts(api: String, payload: [String: Any], extensionID: String) async throws -> Any? {
        switch api {
        case "dnr.updateDynamicRules", "dnr.updateSessionRules", "dnr.updateEnabledRulesets":
            try await requireDNRPermission(extensionID)
            let dnrStore = BrownBearServices.shared.webExtensionDNRStore
            if api == "dnr.updateDynamicRules" {
                try await dnrStore.updateDynamicRules(extensionID: extensionID, update: Self.parseRuleUpdate(payload))
            } else if api == "dnr.updateSessionRules" {
                try await dnrStore.updateSessionRules(extensionID: extensionID, update: Self.parseRuleUpdate(payload))
            } else {
                let rulesets = await store.ext(for: extensionID)?.manifest?.declarativeNetRequest ?? []
                try await dnrStore.updateEnabledRulesets(
                    extensionID: extensionID,
                    manifestDefaults: rulesets.filter(\.enabled).map(\.id),
                    allRulesetIDs: rulesets.map(\.id),
                    disable: (payload["disableRulesetIds"] as? [String]) ?? [],
                    enable: (payload["enableRulesetIds"] as? [String]) ?? [])
            }
            NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
            return NSNull()

        case "dnr.getDynamicRules":
            try await requireDNRPermission(extensionID)
            let rules = await BrownBearServices.shared.webExtensionDNRStore.getDynamicRules(extensionID: extensionID)
            return Self.filterRules(rules, ids: payload["ruleIds"] as? [Int])

        case "dnr.getSessionRules":
            try await requireDNRPermission(extensionID)
            let rules = await BrownBearServices.shared.webExtensionDNRStore.getSessionRules(extensionID: extensionID)
            return Self.filterRules(rules, ids: payload["ruleIds"] as? [Int])

        case "dnr.getEnabledRulesets":
            try await requireDNRPermission(extensionID)
            let rulesets = await store.ext(for: extensionID)?.manifest?.declarativeNetRequest ?? []
            let enabled = await BrownBearServices.shared.webExtensionDNRStore
                .enabledRulesetIDs(extensionID: extensionID, manifestDefaults: rulesets.filter(\.enabled).map(\.id))
            return rulesets.map(\.id).filter { enabled.contains($0) }

        case "userScripts.register", "userScripts.update":
            try await requireUserScriptsPermission(extensionID)
            let resolved = try await resolveRegisteredScripts(extensionID: extensionID,
                                                              raw: payload["scripts"] as? [[String: Any]] ?? [])
            let userScriptStore = BrownBearServices.shared.webExtensionUserScriptStore
            if api == "userScripts.register" {
                try await userScriptStore.register(extensionID: extensionID, scripts: resolved)
            } else {
                try await userScriptStore.update(extensionID: extensionID, scripts: resolved)
            }
            return NSNull()

        case "userScripts.getScripts":
            try await requireUserScriptsPermission(extensionID)
            let filter = (payload["filter"] as? [String: Any])?["ids"] as? [String]
            let scripts = await BrownBearServices.shared.webExtensionUserScriptStore
                .getScripts(extensionID: extensionID, ids: filter)
            return scripts.map(Self.userScriptDict)

        case "userScripts.unregister":
            try await requireUserScriptsPermission(extensionID)
            let ids = (payload["filter"] as? [String: Any])?["ids"] as? [String]
            await BrownBearServices.shared.webExtensionUserScriptStore.unregister(extensionID: extensionID, ids: ids)
            return NSNull()

        case "userScripts.configureWorld":
            try await requireUserScriptsPermission(extensionID)
            let properties = payload["properties"] as? [String: Any] ?? [:]
            let config = WebExtensionUserScriptStore.WorldConfig(
                worldId: properties["worldId"] as? String,
                csp: properties["csp"] as? String,
                messaging: (properties["messaging"] as? Bool) ?? false)
            await BrownBearServices.shared.webExtensionUserScriptStore.configureWorld(extensionID: extensionID, config: config)
            return NSNull()

        case "userScripts.resetWorldConfiguration":
            try await requireUserScriptsPermission(extensionID)
            await BrownBearServices.shared.webExtensionUserScriptStore.resetWorldConfiguration(
                extensionID: extensionID, worldId: payload["worldId"] as? String)
            return NSNull()

        default:
            throw BrownBearError.bridgeRejected("unsupported api '\(api)'")
        }
    }

    /// declarativeNetRequest is privileged: require the API permission before any read OR write.
    private func requireDNRPermission(_ extensionID: String) async throws {
        let perms = await store.ext(for: extensionID)?.manifest?.permissions ?? []
        guard perms.contains("declarativeNetRequest") || perms.contains("declarativeNetRequestWithHostAccess") else {
            throw BrownBearError.bridgeRejected("declarativeNetRequest permission not granted")
        }
    }

    private func requireUserScriptsPermission(_ extensionID: String) async throws {
        // Tampermonkey declares "userScripts" in its MV3 permissions yet hit "permission not granted" on
        // device — meaning at register-time the lookup yields no manifest, or its permissions don't carry
        // the entry. Name the actual state so the next device run pins lookup-miss vs MV-misdetect vs a
        // genuinely-absent permission, instead of the opaque message.
        let ext = await store.ext(for: extensionID)
        let perms = ext?.manifest?.permissions ?? []
        guard perms.contains("userScripts") else {
            throw BrownBearError.bridgeRejected(
                "userScripts permission not granted (extLoaded=\(ext != nil) "
                + "mv=\(ext?.manifest?.manifestVersion ?? 0) perms=[\(perms.sorted().joined(separator: ","))])")
        }
    }


    /// Build a RuleUpdate from a chrome update payload (addRules + removeRuleIds).
    static func parseRuleUpdate(_ payload: [String: Any]) -> WebExtensionDNRStore.RuleUpdate {
        WebExtensionDNRStore.RuleUpdate(
            removeRuleIDs: (payload["removeRuleIds"] as? [Int]) ?? [],
            addRules: (payload["addRules"] as? [[String: Any]]) ?? [])
    }

    /// chrome's get*Rules takes an optional ruleIds filter.
    static func filterRules(_ rules: [[String: Any]], ids: [Int]?) -> [[String: Any]] {
        guard let ids else { return rules }
        let wanted = Set(ids)
        return rules.filter { ($0["id"] as? Int).map(wanted.contains) ?? false }
    }

    static func userScriptDict(_ script: WebExtensionUserScriptStore.RegisteredScript) -> [String: Any] {
        [
            "id": script.id,
            "matches": script.matches,
            "excludeMatches": script.excludeMatches,
            "includeGlobs": script.includeGlobs,
            "excludeGlobs": script.excludeGlobs,
            "js": [["code": script.js]],   // chrome returns ScriptSource[]; we round-trip resolved code
            "runAt": script.runAt,
            "allFrames": script.allFrames,
            "world": script.world
        ]
    }

    /// Resolve register/update ScriptSource[] (each { code } OR { file }) to a flat source string and
    /// normalize match/run-at fields. A `file` is read from the extension's package (containment-safe).
    /// Fails closed if a script has neither code nor a readable file, or no matches.
    private func resolveRegisteredScripts(extensionID: String,
                                          raw: [[String: Any]]) async throws -> [WebExtensionUserScriptStore.RegisteredScript] {
        var out: [WebExtensionUserScriptStore.RegisteredScript] = []
        for entry in raw {
            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: every script needs an id")
            }
            let matches = (entry["matches"] as? [String]) ?? []
            guard !matches.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: script '\(id)' has no matches")
            }
            var source = ""
            for js in (entry["js"] as? [[String: Any]]) ?? [] {
                if let code = js["code"] as? String {
                    source += code + "\n;\n"
                } else if let file = js["file"] as? String,
                          let text = await store.text(extensionID: extensionID, path: file) {
                    source += text + "\n;\n"
                }
            }
            guard !source.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: script '\(id)' has no usable js")
            }
            out.append(WebExtensionUserScriptStore.RegisteredScript(
                id: id,
                matches: matches,
                excludeMatches: (entry["excludeMatches"] as? [String]) ?? [],
                includeGlobs: (entry["includeGlobs"] as? [String]) ?? [],
                excludeGlobs: (entry["excludeGlobs"] as? [String]) ?? [],
                js: source,
                runAt: (entry["runAt"] as? String) ?? "document_idle",
                allFrames: (entry["allFrames"] as? Bool) ?? false,
                world: (entry["world"] as? String) ?? "USER_SCRIPT"))
        }
        return out
    }
}
