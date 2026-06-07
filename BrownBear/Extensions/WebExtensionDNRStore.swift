//
//  WebExtensionDNRStore.swift
//  BrownBear
//
//  Backs chrome.declarativeNetRequest's RUNTIME rule sets — the parts a Manifest V3 extension can
//  change while running, on top of the static rulesets it ships in `manifest.json`:
//
//    • Dynamic rules   — persisted across launches (Chrome contract), per extension.
//    • Session rules   — in-memory only, cleared on app restart, per extension.
//    • Enabled rulesets — which static rulesets are active, overriding the manifest's `enabled`
//                          defaults (updateEnabledRulesets / getEnabledRulesets).
//
//  Rules are arbitrary DNR JSON objects ([String: Any]); since that isn't Codable we persist the
//  dynamic set and the enabled-ruleset selection as JSON in UserDefaults, mirroring the
//  WebExtensionStorage pattern. An actor: the chrome.* bridge (content/popup/background) and the
//  content blocker all read/write it.
//
//  This type owns ONLY storage + Chrome's validation/limits. The static+dynamic+session MERGE that
//  feeds the WKContentRuleList compiler is the pure `DeclarativeNetRequestRuleMerge`, kept separate
//  so it stays unit-testable without a web view or persistence.
//

import Foundation

actor WebExtensionDNRStore {

    /// Chrome's documented ceilings. We enforce them so a misbehaving extension can't grow the rule
    /// set without bound (every rule becomes a compiled WKContentRuleList entry).
    enum Limits {
        static let maxDynamicRules = 30_000
        static let maxSessionRules = 30_000
    }

    /// An update request: add these rules, after removing any with these ids. Mirrors Chrome's
    /// `UpdateRuleOptions` (`addRules` + `removeRuleIds`).
    struct RuleUpdate {
        var removeRuleIDs: [Int]
        var addRules: [[String: Any]]
    }

    /// Dynamic rules survive restarts; persisted as JSON per extension.
    private var dynamic: [String: [[String: Any]]] = [:]
    /// Session rules live only for this process lifetime.
    private var session: [String: [[String: Any]]] = [:]
    /// Static ruleset ids the extension has explicitly enabled/disabled at runtime, overriding the
    /// manifest defaults. `nil` for an extension means "use the manifest defaults".
    private var enabledRulesetOverride: [String: Set<String>] = [:]
    /// Extensions whose dynamic/enabled state has been hydrated from disk this session.
    private var hydrated: Set<String> = []

    private let defaults: UserDefaults

    init(suiteName: String = "com.brownbear.webext") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - Dynamic rules (persisted)

    func getDynamicRules(extensionID: String) -> [[String: Any]] {
        hydrate(extensionID)
        return dynamic[extensionID] ?? []
    }

    /// Apply an add/remove update to the dynamic set. Enforces Chrome's "no duplicate ids within the
    /// set" and the dynamic-rule cap; throws (fail closed) rather than committing a partial update.
    func updateDynamicRules(extensionID: String, update: RuleUpdate) throws {
        hydrate(extensionID)
        let current = dynamic[extensionID] ?? []
        let next = try apply(update, to: current, limit: Limits.maxDynamicRules, label: "dynamic")
        dynamic[extensionID] = next
        persistDynamic(extensionID)
    }

    // MARK: - Session rules (in-memory)

    func getSessionRules(extensionID: String) -> [[String: Any]] {
        session[extensionID] ?? []
    }

    func updateSessionRules(extensionID: String, update: RuleUpdate) throws {
        let current = session[extensionID] ?? []
        let next = try apply(update, to: current, limit: Limits.maxSessionRules, label: "session")
        session[extensionID] = next
    }

    // MARK: - Enabled static rulesets

    /// The static ruleset ids currently enabled for an extension. `manifestDefaults` is the set the
    /// manifest ships marked `enabled: true`; a runtime override (if any) replaces it wholesale.
    func enabledRulesetIDs(extensionID: String, manifestDefaults: [String]) -> Set<String> {
        hydrate(extensionID)
        return enabledRulesetOverride[extensionID] ?? Set(manifestDefaults)
    }

    /// updateEnabledRulesets — disable then enable, applied against the current effective set.
    /// `allRulesetIDs` is every static ruleset the manifest declares, so we reject unknown ids
    /// (Chrome rejects ids that don't name a declared ruleset).
    func updateEnabledRulesets(extensionID: String,
                               manifestDefaults: [String],
                               allRulesetIDs: [String],
                               disable: [String],
                               enable: [String]) throws {
        hydrate(extensionID)
        let known = Set(allRulesetIDs)
        for id in disable + enable where !known.contains(id) {
            throw BrownBearError.bridgeRejected("declarativeNetRequest: unknown ruleset id '\(id)'")
        }
        var effective = enabledRulesetOverride[extensionID] ?? Set(manifestDefaults)
        for id in disable { effective.remove(id) }
        for id in enable { effective.insert(id) }
        enabledRulesetOverride[extensionID] = effective
        persistEnabled(extensionID)
    }

    // MARK: - Cleanup

    /// Drop everything for an extension (called on uninstall).
    func clearAll(extensionID: String) {
        dynamic.removeValue(forKey: extensionID)
        session.removeValue(forKey: extensionID)
        enabledRulesetOverride.removeValue(forKey: extensionID)
        defaults.removeObject(forKey: dynamicKey(extensionID))
        defaults.removeObject(forKey: enabledKey(extensionID))
    }

    // MARK: - Update application

    /// Remove the ids in `update.removeRuleIDs`, then append `update.addRules`. Validates that every
    /// added rule has an integer id, that the resulting set has no duplicate ids, and that it stays
    /// within `limit`. Returns the new set or throws without mutating anything.
    private func apply(_ update: RuleUpdate, to current: [[String: Any]],
                       limit: Int, label: String) throws -> [[String: Any]] {
        let removing = Set(update.removeRuleIDs)
        var next = current.filter { rule in
            guard let id = rule["id"] as? Int else { return true }
            return !removing.contains(id)
        }

        var seen = Set(next.compactMap { $0["id"] as? Int })
        for rule in update.addRules {
            guard let id = rule["id"] as? Int else {
                throw BrownBearError.bridgeRejected("declarativeNetRequest: \(label) rule is missing an integer id")
            }
            if seen.contains(id) {
                throw BrownBearError.bridgeRejected("declarativeNetRequest: duplicate \(label) rule id \(id)")
            }
            seen.insert(id)
            next.append(rule)
        }

        if next.count > limit {
            throw BrownBearError.bridgeRejected("declarativeNetRequest: \(label) rule count \(next.count) exceeds the limit of \(limit)")
        }
        return next
    }

    // MARK: - Persistence (JSON in UserDefaults — DNR rules aren't Codable)

    private func dynamicKey(_ extensionID: String) -> String { "webext.dnr.dynamic.\(extensionID)" }
    private func enabledKey(_ extensionID: String) -> String { "webext.dnr.enabled.\(extensionID)" }

    private func hydrate(_ extensionID: String) {
        guard !hydrated.contains(extensionID) else { return }
        hydrated.insert(extensionID)

        if let data = defaults.data(forKey: dynamicKey(extensionID)),
           let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            dynamic[extensionID] = array
        }
        if let data = defaults.data(forKey: enabledKey(extensionID)),
           let ids = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
            enabledRulesetOverride[extensionID] = Set(ids)
        }
    }

    private func persistDynamic(_ extensionID: String) {
        let rules = dynamic[extensionID] ?? []
        if rules.isEmpty {
            defaults.removeObject(forKey: dynamicKey(extensionID))
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: rules) {
            defaults.set(data, forKey: dynamicKey(extensionID))
        }
    }

    private func persistEnabled(_ extensionID: String) {
        guard let ids = enabledRulesetOverride[extensionID] else {
            defaults.removeObject(forKey: enabledKey(extensionID))
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: Array(ids).sorted()) {
            defaults.set(data, forKey: enabledKey(extensionID))
        }
    }
}
