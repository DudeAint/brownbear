//
//  WebExtensionBackgroundContext+Scripting.swift
//  BrownBear
//
//  The background worker's chrome.scripting / MV2 tabs.executeScript dispatch, split out of the main
//  context file (file-length limit). The worker is the primary scripting caller, so the injection is
//  gated here on permission + host access to the target tab's origin (CLAUDE.md §5 — fail closed).
//

import Foundation

extension WebExtensionBackgroundContext {

    /// Map a chrome.scripting method to the bridge host, resolving `files` from the extension package.
    /// Denies (returns the empty/void shape) unless the extension holds the injection permission AND
    /// host access to the target tab's current origin.
    @MainActor
    static func dispatchScripting(host: WebExtensionBridgeHost, method: String,
                                  args: [String: Any], extensionID: String) async -> Any {
        let store = BrownBearServices.shared.webExtensionStore
        let target = args["target"] as? [String: Any] ?? [:]
        let tabId = target["tabId"] as? Int ?? (args["tabId"] as? Int)
        // Gate injection on permission + host access to the TARGET tab's origin. Fail closed: deny on an
        // unknown tab/manifest or an origin the extension wasn't granted — closing the injection hole.
        let denied: Any = (method == "executeScript") ? [] : NSNull()
        guard let manifest = await store.ext(for: extensionID)?.manifest else { return denied }
        let hasApiPermission = manifest.manifestVersion >= 3
            ? manifest.permissions.contains("scripting")
            : (manifest.permissions.contains("tabs") || manifest.permissions.contains("activeTab"))
        guard hasApiPermission,
              let record = host.webExtTab(extTabId: tabId),
              let tabURL = record["url"] as? String, !tabURL.isEmpty else { return denied }
        let activeTabGrant = manifest.permissions.contains("activeTab")
            && record["id"] as? Int == host.webExtActionActiveTabId()
        if !activeTabGrant {
            // host_permissions ONLY — a content_scripts.matches host is not host access (Chrome).
            let matcher = URLMatcher(matches: manifest.hostPermissions,
                                     includes: [], excludes: [], excludeMatches: [])
            guard matcher.matches(tabURL) else { return denied }
        }
        switch method {
        case "executeScript":
            var code = args["code"] as? String ?? ""
            if code.isEmpty {
                for path in (args["files"] as? [String] ?? []) {
                    if let text = await store.text(extensionID: extensionID, path: path) { code += text + "\n;\n" }
                }
            }
            guard !code.isEmpty else { return [] }
            let world = (args["world"] as? String) ?? "ISOLATED"
            return await host.webExtExecuteScript(extTabId: tabId, world: world, code: code)
        case "insertCSS", "removeCSS":
            var css = args["css"] as? String ?? ""
            if css.isEmpty {
                for path in (args["files"] as? [String] ?? []) {
                    if let text = await store.text(extensionID: extensionID, path: path) { css += text + "\n" }
                }
            }
            if method == "insertCSS" { host.webExtInsertCSS(extTabId: tabId, css: css) }
            else { host.webExtRemoveCSS(extTabId: tabId, css: css) }
            return NSNull()
        default:
            return NSNull()
        }
    }

    /// chrome.userScripts.execute(injection) — run JS NOW in a user-script world of the target tab,
    /// returning one InjectionResult ({result, frameId}) per frame. Like dispatchScripting's executeScript
    /// but gated on the `userScripts` permission (not `scripting`) and defaulting to the USER_SCRIPT world
    /// (our isolated content world; only an explicit world:"MAIN" runs in the page world). Fails closed
    /// (empty result) without the permission or host access to the tab's origin.
    @MainActor
    static func dispatchUserScriptExecute(host: WebExtensionBridgeHost, args: [String: Any],
                                          extensionID: String) async -> Any {
        let store = BrownBearServices.shared.webExtensionStore
        let injection = args["injection"] as? [String: Any] ?? [:]
        let target = injection["target"] as? [String: Any] ?? [:]
        let tabId = target["tabId"] as? Int
        guard let manifest = await store.ext(for: extensionID)?.manifest,
              manifest.permissions.contains("userScripts"),
              let record = host.webExtTab(extTabId: tabId),
              let tabURL = record["url"] as? String, !tabURL.isEmpty else { return [] }
        let activeTabGrant = manifest.permissions.contains("activeTab")
            && record["id"] as? Int == host.webExtActionActiveTabId()
        if !activeTabGrant {
            let matcher = URLMatcher(matches: manifest.hostPermissions, includes: [], excludes: [], excludeMatches: [])
            guard matcher.matches(tabURL) else { return [] }
        }
        var code = ""
        for js in (injection["js"] as? [[String: Any]]) ?? [] {
            if let inline = js["code"] as? String { code += inline + "\n;\n" }
            else if let file = js["file"] as? String,
                    let text = await store.text(extensionID: extensionID, path: file) { code += text + "\n;\n" }
        }
        guard !code.isEmpty else { return [] }
        // USER_SCRIPT (or any non-MAIN world) runs in our single isolated content world; only MAIN is the page.
        let world = ((injection["world"] as? String)?.uppercased() == "MAIN") ? "MAIN" : "USER_SCRIPT"
        return await host.webExtExecuteScript(extTabId: tabId, world: world, code: code)
    }

    // MARK: - chrome.scripting.registerContentScripts (MV3 dynamic content scripts)

    /// The chrome.scripting methods that register/inspect dynamic content scripts (vs the tab-targeted
    /// executeScript/insertCSS), so the native dispatch can route them to the store rather than a tab.
    static let registeredContentScriptMethods: Set<String> = [
        "registerContentScripts", "updateContentScripts", "getRegisteredContentScripts", "unregisterContentScripts"
    ]

    /// Register/update/list/unregister dynamic content scripts. Backed by the shared user-script store,
    /// which the content router already injects into matching pages, so registered scripts run exactly
    /// like manifest content scripts. Gated on the "scripting" permission; fails closed otherwise.
    @MainActor
    static func dispatchRegisteredContentScripts(extensionID: String, method: String,
                                                 args: [String: Any]) async -> Any {
        let services = BrownBearServices.shared
        guard let manifest = await services.webExtensionStore.ext(for: extensionID)?.manifest,
              manifest.permissions.contains("scripting") else {
            return ["error": "the \"scripting\" permission is not granted"]
        }
        let usStore = services.webExtensionUserScriptStore
        let ids = (args["filter"] as? [String: Any])?["ids"] as? [String]
        do {
            switch method {
            case "registerContentScripts":
                try await usStore.register(extensionID: extensionID,
                                           scripts: try await resolveRegisteredContentScripts(extensionID: extensionID, args: args))
                return NSNull()
            case "updateContentScripts":
                try await usStore.update(extensionID: extensionID,
                                         scripts: try await resolveRegisteredContentScripts(extensionID: extensionID, args: args))
                return NSNull()
            case "getRegisteredContentScripts":
                return (await usStore.getScripts(extensionID: extensionID, ids: ids)).map(registeredContentScriptDict)
            case "unregisterContentScripts":
                await usStore.unregister(extensionID: extensionID, ids: ids)
                return NSNull()
            default:
                return NSNull()
            }
        } catch let error as BrownBearError {
            return ["error": error.errorDescription ?? "scripting.registerContentScripts error"]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// The chrome RegisteredContentScript shape for `getRegisteredContentScripts` (we don't echo the
    /// resolved js source back — Chrome returns the file list, which we don't retain; ids + match
    /// metadata is what callers reconcile against).
    private static func registeredContentScriptDict(_ s: WebExtensionUserScriptStore.RegisteredScript) -> [String: Any] {
        ["id": s.id, "matches": s.matches, "excludeMatches": s.excludeMatches,
         "runAt": s.runAt, "allFrames": s.allFrames, "world": s.world, "persistAcrossSessions": true]
    }

    /// Resolve chrome.scripting.registerContentScripts entries (whose `js`/`css` are arrays of packaged
    /// FILE PATHS) into the store's RegisteredScript model, concatenating the js sources. Default world
    /// is ISOLATED (the extension content-script world), unlike userScripts' USER_SCRIPT default.
    @MainActor
    private static func resolveRegisteredContentScripts(
        extensionID: String, args: [String: Any]) async throws -> [WebExtensionUserScriptStore.RegisteredScript] {
        let store = BrownBearServices.shared.webExtensionStore
        var out: [WebExtensionUserScriptStore.RegisteredScript] = []
        for entry in (args["scripts"] as? [[String: Any]]) ?? [] {
            guard let id = entry["id"] as? String, !id.isEmpty else {
                throw BrownBearError.bridgeRejected("scripting.registerContentScripts: every script needs an id")
            }
            let matches = (entry["matches"] as? [String]) ?? []
            guard !matches.isEmpty else {
                throw BrownBearError.bridgeRejected("scripting.registerContentScripts: script '\(id)' has no matches")
            }
            var source = ""
            for path in (entry["js"] as? [String]) ?? [] {
                if let text = await store.text(extensionID: extensionID, path: path) { source += text + "\n;\n" }
            }
            guard !source.isEmpty else {
                throw BrownBearError.bridgeRejected("scripting.registerContentScripts: script '\(id)' has no usable js")
            }
            out.append(.init(id: id, matches: matches,
                             excludeMatches: (entry["excludeMatches"] as? [String]) ?? [],
                             includeGlobs: (entry["includeGlobs"] as? [String]) ?? [],
                             excludeGlobs: (entry["excludeGlobs"] as? [String]) ?? [],
                             js: source, runAt: (entry["runAt"] as? String) ?? "document_idle",
                             allFrames: (entry["allFrames"] as? Bool) ?? false,
                             world: (entry["world"] as? String) ?? "ISOLATED"))
        }
        return out
    }
}
