//
//  WebExtensionUserScriptStore.swift
//  BrownBear
//
//  Backs chrome.userScripts (MV3) — the API that lets an extension register arbitrary user scripts
//  at runtime, the way a userscript manager (Tampermonkey-style) ships inside an extension. Each
//  registered script is, mechanically, a content script: it has match patterns, a run-at, and JS,
//  and BrownBear injects it through the SAME content-script path the manifest's `content_scripts`
//  use. So this store keeps the registered set per extension (persisted) and the content-script
//  resolver folds it in alongside the manifest scripts.
//
//  iOS limits: WKWebView can't apply a custom per-world CSP. We can't honor configureWorld({csp}) by
//  setting that CSP on a world — BUT a manager configures a userScript-world CSP (with 'unsafe-eval') so
//  its userscripts can decode + eval obfuscated code regardless of the PAGE's CSP, and our ISOLATED
//  content world is already CSP-immune. So we DO honor the intent: a manager that declared an eval-CSP has
//  its non-broker MAIN userscripts routed to the isolated world (see AppSettings.effectiveWorld +
//  WebExtensionMessageRouter.getContentScripts), where their runtime eval works. The csp/world fields are
//  recorded so getScripts/configureWorld round-trip faithfully.
//
//  An actor: the chrome.* bridge (content/popup/background) and the content-script resolver read it.
//

import Foundation

actor WebExtensionUserScriptStore {

    /// A registered user script. `js` is the resolved source — userScripts.register passes code
    /// inline (`{ code }`) or by file (`{ file }`); we resolve files to text at register time so the
    /// content-script resolver only ever deals with source strings.
    struct RegisteredScript: Codable, Equatable {
        var id: String
        var matches: [String]
        var excludeMatches: [String]
        var includeGlobs: [String]
        var excludeGlobs: [String]
        var js: String
        var runAt: String          // document_start | document_end | document_idle
        var allFrames: Bool
        var world: String          // USER_SCRIPT | MAIN — recorded; iOS runs both in our isolated world
    }

    /// configureWorld settings. We persist them so getScripts/CSP round-trips, even though iOS can't
    /// enforce a per-world CSP or messaging flag on a single shared isolated world.
    struct WorldConfig: Codable, Equatable {
        var worldId: String?
        var csp: String?
        var messaging: Bool
    }

    private var scripts: [String: [RegisteredScript]] = [:]   // extensionID → registered scripts
    private var worlds: [String: [WorldConfig]] = [:]         // extensionID → world configs
    private var hydrated: Set<String> = []
    private let defaults: UserDefaults

    init(suiteName: String = "com.brownbear.webext") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - register / getScripts / unregister / update

    /// chrome.userScripts.register — add scripts. Rejects (fail closed, atomic) a duplicate id or an
    /// id that's already registered, matching Chrome.
    func register(extensionID: String, scripts incoming: [RegisteredScript]) throws {
        hydrate(extensionID)
        var current = scripts[extensionID] ?? []
        let existing = Set(current.map(\.id))
        var seen = Set<String>()
        for script in incoming {
            guard !script.id.isEmpty else {
                throw BrownBearError.bridgeRejected("userScripts.register: every script needs an id")
            }
            if existing.contains(script.id) || seen.contains(script.id) {
                throw BrownBearError.bridgeRejected("userScripts.register: duplicate script id '\(script.id)'")
            }
            seen.insert(script.id)
        }
        current.append(contentsOf: incoming)
        scripts[extensionID] = current
        persistScripts(extensionID)
    }

    /// chrome.userScripts.getScripts — all registered, or only those whose id is in `ids`.
    func getScripts(extensionID: String, ids: [String]?) -> [RegisteredScript] {
        hydrate(extensionID)
        let all = scripts[extensionID] ?? []
        guard let ids else { return all }
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }
    }

    /// chrome.userScripts.unregister — remove by id, or ALL when `ids` is nil.
    func unregister(extensionID: String, ids: [String]?) {
        hydrate(extensionID)
        guard let ids else {
            scripts[extensionID] = []
            persistScripts(extensionID)
            return
        }
        let dropping = Set(ids)
        scripts[extensionID] = (scripts[extensionID] ?? []).filter { !dropping.contains($0.id) }
        persistScripts(extensionID)
    }

    /// chrome.userScripts.update — replace fields of already-registered scripts. Each incoming script
    /// must name an existing id; we merge it in (Chrome's update replaces the whole script body for
    /// the given id). Rejects an unknown id without mutating anything.
    func update(extensionID: String, scripts incoming: [RegisteredScript]) throws {
        hydrate(extensionID)
        var current = scripts[extensionID] ?? []
        let index = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($1.id, $0) })
        for script in incoming where index[script.id] == nil {
            throw BrownBearError.bridgeRejected("userScripts.update: no registered script with id '\(script.id)'")
        }
        for script in incoming {
            if let position = index[script.id] { current[position] = script }
        }
        scripts[extensionID] = current
        persistScripts(extensionID)
    }

    // MARK: - configureWorld

    /// chrome.userScripts.configureWorld — store the requested world settings (per worldId, with a
    /// nil worldId being the default USER_SCRIPT world). Re-configuring the same worldId replaces it.
    func configureWorld(extensionID: String, config: WorldConfig) {
        hydrate(extensionID)
        var list = worlds[extensionID] ?? []
        list.removeAll { $0.worldId == config.worldId }
        list.append(config)
        worlds[extensionID] = list
        persistWorlds(extensionID)
    }

    func worldConfigs(extensionID: String) -> [WorldConfig] {
        hydrate(extensionID)
        return worlds[extensionID] ?? []
    }

    /// chrome.userScripts.resetWorldConfiguration — drop the config for `worldId` (nil = default world),
    /// so it reverts to defaults (e.g. messaging:false). Without this, a configureWorld({messaging:true})
    /// stays persisted and the userScript messaging channel stays on after a reset.
    func resetWorldConfiguration(extensionID: String, worldId: String?) {
        hydrate(extensionID)
        guard var list = worlds[extensionID], list.contains(where: { $0.worldId == worldId }) else { return }
        list.removeAll { $0.worldId == worldId }
        worlds[extensionID] = list
        persistWorlds(extensionID)
    }

    // MARK: - Cleanup

    func clearAll(extensionID: String) {
        scripts.removeValue(forKey: extensionID)
        worlds.removeValue(forKey: extensionID)
        defaults.removeObject(forKey: scriptsKey(extensionID))
        defaults.removeObject(forKey: worldsKey(extensionID))
    }

    // MARK: - Persistence

    private func scriptsKey(_ extensionID: String) -> String { "webext.userscripts.\(extensionID)" }
    private func worldsKey(_ extensionID: String) -> String { "webext.userscripts.worlds.\(extensionID)" }

    private func hydrate(_ extensionID: String) {
        guard !hydrated.contains(extensionID) else { return }
        hydrated.insert(extensionID)
        if let data = defaults.data(forKey: scriptsKey(extensionID)),
           let decoded = try? JSONDecoder.brownBear.decode([RegisteredScript].self, from: data) {
            scripts[extensionID] = decoded
        }
        if let data = defaults.data(forKey: worldsKey(extensionID)),
           let decoded = try? JSONDecoder.brownBear.decode([WorldConfig].self, from: data) {
            worlds[extensionID] = decoded
        }
    }

    private func persistScripts(_ extensionID: String) {
        let list = scripts[extensionID] ?? []
        if list.isEmpty {
            defaults.removeObject(forKey: scriptsKey(extensionID))
            return
        }
        if let data = try? JSONEncoder.brownBear.encode(list) {
            defaults.set(data, forKey: scriptsKey(extensionID))
        }
    }

    private func persistWorlds(_ extensionID: String) {
        let list = worlds[extensionID] ?? []
        if list.isEmpty {
            defaults.removeObject(forKey: worldsKey(extensionID))
            return
        }
        if let data = try? JSONEncoder.brownBear.encode(list) {
            defaults.set(data, forKey: worldsKey(extensionID))
        }
    }
}
