//
//  WebExtensionBackgroundContext+DNRUserScripts.swift
//  BrownBear
//
//  The background worker's chrome.declarativeNetRequest (dynamic/session/enabled-ruleset) and
//  chrome.userScripts dispatch — the static, store-only halves of the natives installed in
//  WebExtensionBackgroundContext. Split into its own file purely to keep that file under the length
//  limit; these are `static` and reach only BrownBearServices.shared + the public store APIs (no
//  instance-private state), so a separate-file extension is sufficient.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// Map a chrome.declarativeNetRequest method + args to the shared stores (main actor). A thrown
    /// guard becomes {"error": message} so the JS shim can reject the promise faithfully.
    @MainActor
    static func dispatchDNR(extensionID: String, method: String, args: [String: Any]) async -> Any {
        let services = BrownBearServices.shared
        let dnrStore = services.webExtensionDNRStore
        let ext = await services.webExtensionStore.ext(for: extensionID)
        let manifest = ext?.manifest
        // Effective permissions = the manifest's declared permissions UNION the optional ones the user
        // granted at runtime via chrome.permissions.request. An EWE-based blocker (AdBlock/ABP) can
        // declare declarativeNetRequest as OPTIONAL and request it on first run, so gating on the declared
        // set alone rejected every DNR call ("declarativeNetRequest permission not granted") and the
        // blocker couldn't register any rules. The diagnostic names the actual state so the next device
        // log distinguishes a genuine absence from a manifest-lookup miss (the userScripts gate's lesson).
        let granted = await services.webExtensionPermissionGrants.granted(extensionID: extensionID)
        let perms = Set(manifest?.permissions ?? []).union(granted.permissions)
        guard perms.contains("declarativeNetRequest") || perms.contains("declarativeNetRequestWithHostAccess") else {
            return ["error": "declarativeNetRequest permission not granted (extLoaded=\(ext != nil) "
                + "mv=\(manifest?.manifestVersion ?? 0) perms=[\(perms.sorted().joined(separator: ","))])"]
        }
        do {
            switch method {
            case "getDynamicRules":
                return dnrFilterRules(await dnrStore.getDynamicRules(extensionID: extensionID), ids: args["ruleIds"] as? [Int])
            case "getSessionRules":
                return dnrFilterRules(await dnrStore.getSessionRules(extensionID: extensionID), ids: args["ruleIds"] as? [Int])
            case "updateDynamicRules":
                try await dnrStore.updateDynamicRules(extensionID: extensionID, update: dnrRuleUpdate(args))
                NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                return NSNull()
            case "updateSessionRules":
                try await dnrStore.updateSessionRules(extensionID: extensionID, update: dnrRuleUpdate(args))
                NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                return NSNull()
            case "getEnabledRulesets":
                let rulesets = manifest?.declarativeNetRequest ?? []
                let enabled = await dnrStore.enabledRulesetIDs(extensionID: extensionID,
                                                               manifestDefaults: rulesets.filter(\.enabled).map(\.id))
                return rulesets.map(\.id).filter { enabled.contains($0) }
            case "updateEnabledRulesets":
                let rulesets = manifest?.declarativeNetRequest ?? []
                try await dnrStore.updateEnabledRulesets(
                    extensionID: extensionID,
                    manifestDefaults: rulesets.filter(\.enabled).map(\.id),
                    allRulesetIDs: rulesets.map(\.id),
                    disable: (args["disableRulesetIds"] as? [String]) ?? [],
                    enable: (args["enableRulesetIds"] as? [String]) ?? [])
                NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                return NSNull()
            default:
                return NSNull()
            }
        } catch let error as BrownBearError {
            return ["error": error.errorDescription ?? "declarativeNetRequest error"]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Map a chrome.userScripts method + args to the shared store on the main actor.
    @MainActor
    static func dispatchUserScripts(extensionID: String, method: String, args: [String: Any]) async -> Any {
        let services = BrownBearServices.shared
        let usStore = services.webExtensionUserScriptStore
        // Diagnostic (Tampermonkey declares userScripts in MV3 yet hit this on device): name the actual
        // store state so the next device log distinguishes a lookup miss / MV mis-detection from a
        // genuinely-absent permission, rather than the opaque "not granted".
        let ext = await services.webExtensionStore.ext(for: extensionID)
        let perms = ext?.manifest?.permissions ?? []
        guard perms.contains("userScripts") else {
            return ["error": "userScripts permission not granted (extLoaded=\(ext != nil) "
                + "mv=\(ext?.manifest?.manifestVersion ?? 0) perms=[\(perms.sorted().joined(separator: ","))])"]
        }
        do {
            switch method {
            case "register":
                try await usStore.register(extensionID: extensionID,
                                           scripts: try await resolveUserScripts(extensionID: extensionID, args: args))
                return NSNull()
            case "update":
                try await usStore.update(extensionID: extensionID,
                                         scripts: try await resolveUserScripts(extensionID: extensionID, args: args))
                return NSNull()
            case "getScripts":
                let ids = (args["filter"] as? [String: Any])?["ids"] as? [String]
                return (await usStore.getScripts(extensionID: extensionID, ids: ids)).map(dnrUserScriptDict)
            case "unregister":
                let ids = (args["filter"] as? [String: Any])?["ids"] as? [String]
                await usStore.unregister(extensionID: extensionID, ids: ids)
                return NSNull()
            case "configureWorld":
                let properties = args["properties"] as? [String: Any] ?? [:]
                await usStore.configureWorld(extensionID: extensionID, config: .init(
                    worldId: properties["worldId"] as? String, csp: properties["csp"] as? String,
                    messaging: (properties["messaging"] as? Bool) ?? false))
                return NSNull()
            case "resetWorldConfiguration":
                await usStore.resetWorldConfiguration(extensionID: extensionID, worldId: args["worldId"] as? String)
                return NSNull()
            case "getWorldConfigurations":
                // chrome.userScripts.getWorldConfigurations() → the persisted per-world settings, as Chrome's
                // WorldProperties ([{worldId?, csp?, messaging}]). A nil worldId is the default USER_SCRIPT world.
                return (await usStore.worldConfigs(extensionID: extensionID)).map { config -> [String: Any] in
                    var dict: [String: Any] = ["messaging": config.messaging]
                    dict["worldId"] = config.worldId ?? NSNull()
                    dict["csp"] = config.csp ?? NSNull()
                    return dict
                }
            default:
                return NSNull()
            }
        } catch let error as BrownBearError {
            return ["error": error.errorDescription ?? "userScripts error"]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - DNR / userScripts arg helpers (pure)

    private static func dnrRuleUpdate(_ args: [String: Any]) -> WebExtensionDNRStore.RuleUpdate {
        WebExtensionDNRStore.RuleUpdate(
            removeRuleIDs: (args["removeRuleIds"] as? [Int]) ?? [],
            addRules: (args["addRules"] as? [[String: Any]]) ?? [])
    }

    private static func dnrFilterRules(_ rules: [[String: Any]], ids: [Int]?) -> [[String: Any]] {
        guard let ids else { return rules }
        let wanted = Set(ids)
        return rules.filter { ($0["id"] as? Int).map(wanted.contains) ?? false }
    }

    private static func dnrUserScriptDict(_ script: WebExtensionUserScriptStore.RegisteredScript) -> [String: Any] {
        [
            "id": script.id, "matches": script.matches, "excludeMatches": script.excludeMatches,
            "includeGlobs": script.includeGlobs, "excludeGlobs": script.excludeGlobs,
            "js": [["code": script.js]], "runAt": script.runAt, "allFrames": script.allFrames, "world": script.world
        ]
    }

    @MainActor
    private static func resolveUserScripts(extensionID: String,
                                           args: [String: Any]) async throws -> [WebExtensionUserScriptStore.RegisteredScript] {
        let store = BrownBearServices.shared.webExtensionStore
        var out: [WebExtensionUserScriptStore.RegisteredScript] = []
        for entry in (args["scripts"] as? [[String: Any]]) ?? [] {
            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts: every script needs an id")
            }
            let matches = (entry["matches"] as? [String]) ?? []
            guard !matches.isEmpty else { throw BrownBearError.bridgeRejected("userScripts: script '\(id)' has no matches") }
            var source = ""
            for js in (entry["js"] as? [[String: Any]]) ?? [] {
                if let code = js["code"] as? String { source += code + "\n;\n" }
                else if let file = js["file"] as? String,
                        let text = await store.text(extensionID: extensionID, path: file) { source += text + "\n;\n" }
            }
            guard !source.isEmpty else { throw BrownBearError.bridgeRejected("userScripts: script '\(id)' has no usable js") }
            out.append(.init(id: id, matches: matches,
                             excludeMatches: (entry["excludeMatches"] as? [String]) ?? [],
                             includeGlobs: (entry["includeGlobs"] as? [String]) ?? [],
                             excludeGlobs: (entry["excludeGlobs"] as? [String]) ?? [],
                             js: source, runAt: (entry["runAt"] as? String) ?? "document_idle",
                             allFrames: (entry["allFrames"] as? Bool) ?? false,
                             world: (entry["world"] as? String) ?? "USER_SCRIPT"))
        }
        return out
    }
}
