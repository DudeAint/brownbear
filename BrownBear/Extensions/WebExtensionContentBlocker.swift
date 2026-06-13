//
//  WebExtensionContentBlocker.swift
//  BrownBear
//
//  Bridges an extension's `declarativeNetRequest` static rulesets onto WebKit's only network
//  blocking primitive: the ahead-of-time-compiled `WKContentRuleList`. On every change (install,
//  enable/disable, uninstall) it recompiles the full set from scratch and swaps it into the shared
//  content controller, so blocking takes effect on the next navigation with no per-tab plumbing.
//
//  The DNR→WebKit translation is done by the pure `DeclarativeNetRequest` compiler; this type owns
//  only the WebKit-side compile/install and the diagnostics the dashboard surfaces.
//

import WebKit
import CryptoKit

@MainActor
final class WebExtensionContentBlocker {

    /// What happened to one ruleset on the last refresh — for the dashboard and for tests.
    struct Report: Equatable {
        var extensionID: String
        var extensionName: String
        var rulesetID: String
        var compiledCount: Int
        var skippedCount: Int
        var error: String?
    }

    private let store: WebExtensionStore
    private let dnrStore: WebExtensionDNRStore
    private let ruleListStore: WKContentRuleListStore?
    private(set) var reports: [Report] = []
    /// declarativeNetRequest `redirect` rules for MAIN-FRAME navigations, across all enabled extensions,
    /// priority-ordered. WKContentRuleList can't express `redirect`, so these are matched at navigation
    /// time (see WebExtensionDNRRedirect + the nav delegate). Rebuilt on every refresh; read synchronously.
    private(set) var redirectRules: [WebExtensionDNRRedirect.Rule] = []
    // Single-flight: refresh suspends at every await, and it's fired fire-and-forget from boot AND
    // every extension-change notification. Without coalescing, two overlapping refreshes interleave
    // their remove/add calls and install a stale rule-list set.
    private var isRefreshing = false
    private var refreshRequested = false
    /// Hosts (normalized: lowercased, "www."-stripped) where the user turned Shields OFF for the
    /// site. Captured on the last refresh so a shields-down host is excluded from BrownBear's built-in
    /// tracker list AND from every extension rule that can carry an `unless-domain`.
    private var shieldsDisabledHosts: [String] = []

    init(store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         dnrStore: WebExtensionDNRStore = BrownBearServices.shared.webExtensionDNRStore,
         ruleListStore: WKContentRuleListStore? = WKContentRuleListStore.default()) {
        self.store = store
        self.dnrStore = dnrStore
        self.ruleListStore = ruleListStore
    }

    /// Total rules currently enforced across all installed extensions (for the dashboard summary).
    var activeRuleCount: Int { reports.reduce(0) { $0 + $1.compiledCount } }

    /// Recompile every enabled extension's enabled DNR rulesets and install them into the shared
    /// content controller, replacing whatever was there. Coalesced (single-flight + one trailing
    /// pass) so overlapping calls can't interleave; the swap is atomic.
    func refresh(into userContentController: WKUserContentController,
                 shieldsDisabledHosts: [String] = []) async {
        // Latest caller wins for the exclusion set; a queued trailing pass uses the newest value.
        self.shieldsDisabledHosts = shieldsDisabledHosts
        if isRefreshing { refreshRequested = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshRequested = false
            await performRefresh(into: userContentController)
        } while refreshRequested
    }

    /// The result of preparing one extension's DNR rules off the main actor: the WebKit rule-list JSON to
    /// compile (nil when nothing compiles — redirect-only or empty), the main-frame redirect rules to apply
    /// at navigation time, and the counts/warning for the dashboard report.
    private struct PreparedExtensionRules {
        let json: String?
        let redirect: [WebExtensionDNRRedirect.Rule]
        let compiledCount: Int
        let skippedCount: Int
        let warning: String?
    }

    private func performRefresh(into userContentController: WKUserContentController) async {
        var newReports: [Report] = []
        var compiledLists: [WKContentRuleList] = []
        var newRedirect: [WebExtensionDNRRedirect.Rule] = []
        let exclusions = shieldsDisabledHosts

        // BrownBear's own built-in ad/tracker list, applied to every site EXCEPT the hosts where the
        // user turned Shields off. This is what makes the per-site "Content Blocking" toggle bite even
        // with no extensions installed.
        if let builtin = await compileBuiltInList(excluding: exclusions) {
            compiledLists.append(builtin)
        }

        if let ruleListStore {
            for ext in await store.enabledExtensions() {
                guard let manifest = ext.manifest else { continue }
                // Enabled static rulesets = manifest defaults overlaid with updateEnabledRulesets().
                let manifestDefaults = manifest.declarativeNetRequest.filter(\.enabled).map(\.id)
                let enabledIDs = await dnrStore.enabledRulesetIDs(extensionID: ext.id, manifestDefaults: manifestDefaults)
                // Gather the raw inputs on the main actor (these awaits only SUSPEND — no CPU here). The
                // parse/merge/compile happens off-main below so a big ruleset can't freeze the UI.
                var staticRuleData: [Data] = []
                for ruleset in manifest.declarativeNetRequest where enabledIDs.contains(ruleset.id) {
                    if let data = await store.file(extensionID: ext.id, path: ruleset.path) { staticRuleData.append(data) }
                }
                let dynamicRules = await dnrStore.getDynamicRules(extensionID: ext.id)
                let sessionRules = await dnrStore.getSessionRules(extensionID: ext.id)
                // Nothing to enforce for this extension (no static rulesets AND no runtime rules).
                if staticRuleData.isEmpty && dynamicRules.isEmpty && sessionRules.isEmpty { continue }

                // Parse + merge + DNR-compile + unbreak + exclusions OFF the main actor — this is the
                // per-extension CPU cost that would otherwise freeze scrolling/taps at launch. Pure
                // transform of the gathered inputs; the WebKit compile + install stay on the main actor.
                let extID = ext.id
                let prepared = await Task.detached(priority: .utility) { () -> PreparedExtensionRules in
                    var staticRules: [[String: Any]] = []
                    for data in staticRuleData {
                        if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                            staticRules.append(contentsOf: arr)
                        }
                    }
                    // Merge so dynamic/session override static by rule id (Chrome precedence).
                    let merged = DeclarativeNetRequestRuleMerge.merge(staticRules: staticRules,
                                                                      dynamicRules: dynamicRules,
                                                                      sessionRules: sessionRules)
                    // Extract main-frame redirect rules BEFORE compiling — the content-rule-list compiler
                    // .skip()s `redirect`, so an extension whose ONLY rules are redirects compiles to
                    // nothing but its redirect rules must still be applied at nav time.
                    let redirect = WebExtensionDNRRedirect.redirectRules(from: merged, extensionID: extID)
                    let result = DeclarativeNetRequest.compile(rules: merged)
                    guard !result.isEmpty else {
                        return PreparedExtensionRules(json: nil, redirect: redirect, compiledCount: 0,
                                                      skippedCount: result.skippedCount,
                                                      warning: result.warnings.first ?? "no rules compiled")
                    }
                    // Exclude shields-off hosts from every extension rule that can carry an exclusion (a
                    // rule already pinned with `if-domain` can't also take `unless-domain`, so it is left
                    // unchanged — BrownBear's built-in list still honors the shields-off host). Strip any
                    // page-breaking-agent block this extension's rules would compile in (an extension list
                    // is isolated). No endpoint block — the built-in list already carries those.
                    let unbroken = Self.applyUnbreak(to: result.json, includeEndpointBlocks: false)
                    let scopedJSON = Self.applyExclusions(to: unbroken, hosts: exclusions)
                    return PreparedExtensionRules(json: scopedJSON, redirect: redirect,
                                                  compiledCount: result.compiledCount,
                                                  skippedCount: result.skippedCount, warning: nil)
                }.value

                // A redirect-only (or empty) extension contributes no compiled list, but its redirect
                // rules still apply at navigation time.
                newRedirect.append(contentsOf: prepared.redirect)
                guard let scopedJSON = prepared.json else {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: "(merged)", compiledCount: 0,
                                             skippedCount: prepared.skippedCount,
                                             error: prepared.warning ?? "no rules compiled"))
                    continue
                }
                let identifier = "brownbear-dnr-\(ext.id)"
                do {
                    let list = try await compile(store: ruleListStore, identifier: identifier, json: scopedJSON)
                    compiledLists.append(list)
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: "(merged)", compiledCount: prepared.compiledCount,
                                             skippedCount: prepared.skippedCount, error: nil))
                } catch {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: "(merged)", compiledCount: 0,
                                             skippedCount: prepared.skippedCount,
                                             error: error.localizedDescription))
                }
            }
        }

        // Atomic swap: remove + add happen together with NO await between, so there's never a window
        // where the page is left with a partial rule set.
        userContentController.removeAllContentRuleLists()
        for list in compiledLists { userContentController.add(list) }
        reports = newReports
        // Highest priority first so the matcher's first-match-wins picks the top rule across extensions.
        redirectRules = newRedirect.sorted { $0.priority > $1.priority }
    }

    /// The declarativeNetRequest main-frame redirect target for `url`, or nil if no enabled rule applies.
    /// Synchronous (reads the cache rebuilt on every refresh), so the navigation delegate can consult it
    /// without blocking the hot path. `extensionOrigin` maps an extension id to its chrome-extension origin.
    func redirectTarget(for url: String, extensionOrigin: (String) -> String) -> URL? {
        guard !redirectRules.isEmpty else { return nil }
        return WebExtensionDNRRedirect.target(for: url, rules: redirectRules, extensionOrigin: extensionOrigin)
    }

    private func compile(store: WKContentRuleListStore,
                         identifier: String, json: String) async throws -> WKContentRuleList {
        // WKContentRuleListStore persists each compiled list to disk by identifier, but
        // compileContentRuleList RECOMPILES from scratch on every call — and compiling a large list
        // (EasyList/EasyPrivacy, uBO Lite) takes seconds. On a cold relaunch the rules are almost always
        // byte-for-byte the same as last time, so we hash the source: if it matches what we last compiled
        // under this identifier, reuse the already-compiled list via lookUp (a fast deserialize) instead of
        // paying the full compile again. This is the main lever against the cold-start freeze.
        let hash = Self.stableHash(json)
        if Self.persistedHash(forIdentifier: identifier) == hash,
           let cached = await Self.lookUp(store: store, identifier: identifier) {
            return cached
        }
        let list = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? BrownBearError.bridgeRejected("rule-list compile failed"))
                }
            }
        }
        Self.setPersistedHash(hash, forIdentifier: identifier)
        return list
    }

    /// Fetch an already-compiled list from the store by identifier; nil on a miss (never compiled or
    /// evicted), so the caller falls back to a fresh compile. Off the main thread (the store's own queue).
    private static func lookUp(store: WKContentRuleListStore, identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    // MARK: - Compiled-list source hashing (skip recompiling unchanged rule lists across launches)

    private static let compiledHashesKey = "com.brownbear.dnr.compiledRuleListHashes.v1"

    /// A launch-stable hash of a rule-list's source JSON (Swift's `Hasher` is per-process-randomized, so
    /// it can't be persisted — SHA-256 is stable across launches).
    static func stableHash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func persistedHash(forIdentifier identifier: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: compiledHashesKey) as? [String: String])?[identifier]
    }

    private static func setPersistedHash(_ hash: String, forIdentifier identifier: String) {
        var all = (UserDefaults.standard.dictionary(forKey: compiledHashesKey) as? [String: String]) ?? [:]
        all[identifier] = hash
        UserDefaults.standard.set(all, forKey: compiledHashesKey)
    }

    /// Compile BrownBear's built-in tracker/ad list with the shields-off hosts excluded. Returns nil
    /// (and installs nothing) if the bundled list is missing or fails to compile — a built-in-list
    /// failure must never take the extension lists down with it.
    private func compileBuiltInList(excluding hosts: [String]) async -> WKContentRuleList? {
        guard let ruleListStore else { return nil }
        // Building this JSON means running applyUnbreak + applyExclusions over the full merged
        // EasyList/EasyPrivacy blob (multi-MB) — heavy string work that would freeze the UI if done on the
        // main actor. It's pure (hosts in, JSON out), so run it on a background thread.
        let json = await Task.detached(priority: .utility) { Self.builtInBlocklistJSONOffMain(excluding: hosts) }.value
        guard let json else { return nil }
        return try? await compile(store: ruleListStore, identifier: "brownbear-builtin-blocklist", json: json)
    }

    // MARK: - Built-in list + per-site exclusions (pure helpers, unit-testable)

    /// BrownBear's bundled/network-updated tracker-ad blocklist as WebKit content-rule-list JSON, with the
    /// shields-off hosts injected as a global `unless-domain` so blocking is suppressed there. Prefers the
    /// merged EasyList/EasyPrivacy/Peter Lowe list kept fresh by ContentBlocklistUpdater, falling back to the
    /// small bundled starter list offline / before the first fetch. Nil if neither source is usable.
    ///
    /// Fully off the main actor: it reads the cached merged list via the nonisolated file reader (not the
    /// @MainActor singleton property), so the multi-MB disk read AND the unbreak/exclusion transforms all run
    /// on a background thread instead of freezing the UI at launch.
    nonisolated static func builtInBlocklistJSONOffMain(excluding hosts: [String]) -> String? {
        var json = ContentBlocklistUpdater.loadCachedMergedJSON()
        if json == nil {
            if let url = Bundle.main.url(forResource: "brownbear-blocklist", withExtension: "json", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-blocklist", withExtension: "json", subdirectory: "JS"),
               let data = try? Data(contentsOf: url) {
                json = String(data: data, encoding: .utf8)
            }
        }
        guard let json else { return nil }
        let unbroken = applyUnbreak(to: json, includeEndpointBlocks: true)
        let scoped = applyExclusions(to: unbroken, hosts: hosts)
        return scoped == "[]" ? nil : scoped
    }

    /// A telemetry SCRIPT host that BREAKS the page when blocked, paired with the data ENDPOINT that
    /// carries its actual tracking payload. New Relic is the canonical case: its inline page snippet wraps
    /// `window.addEventListener` with a thunk that delegates to a reference only the external agent
    /// (`js-agent.newrelic.com`) initializes — so blocking the agent leaves that thunk throwing
    /// "addEventListener is not a function", poisoning the page's own global and taking down every
    /// MAIN-world script on the page (the page's code AND any userscript). Blocking the data endpoint
    /// (`nr-data.net`) instead stops the telemetry from ever leaving, with no page breakage.
    private struct UnbreakException {
        let agentHost: String      // the breakage-prone SCRIPT host to NEVER block (any path)
        let endpointFilter: String // its data-collection ENDPOINT url-filter to KEEP blocked (third-party)
    }
    private static let unbreakExceptions: [UnbreakException] = [
        UnbreakException(agentHost: "js-agent.newrelic.com",
                         endpointFilter: "^https?://([^/]+\\.)?nr-data\\.net[:/]")
    ]

    /// Un-break a compiled rule-list JSON: REMOVE every `block` rule that would block a breakage-prone
    /// agent host, and (when `includeEndpointBlocks`) append an explicit third-party block of that agent's
    /// data endpoint so telemetry still can't leave. We STRIP the block rather than append an
    /// `ignore-previous-rules`: WebKit applies an ignore only within the SAME compiled list AND only when
    /// its trigger overlaps the block's resource-type/load-type — fragile and order-sensitive. Deleting the
    /// block is order- and overlap-proof, and (crucially) it must run on EVERY compiled list (the built-in
    /// list AND each extension's), because WKContentRuleLists are isolated and a block in ANY list blocks,
    /// with no cross-list allow. A block "targets" an agent iff its url-filter regex matches the agent's
    /// URL; a cheap second-level-label pre-filter keeps us from compiling all ~50k patterns. The telemetry
    /// endpoint (`nr-data.net`) never matches an agent host, so its block survives. Fails safe (unparseable
    /// JSON returned unchanged). Pure — unit-tested.
    nonisolated static func applyUnbreak(to json: String, includeEndpointBlocks: Bool) -> String {
        guard let data = json.data(using: .utf8),
              var rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return json }
        // A representative URL per agent host (host-targeting tracker rules match any path).
        let probes = unbreakExceptions.map { "https://\($0.agentHost)/nr-spa.min.js" }
        // Cheap pre-filter: only a rule whose url-filter mentions an agent's second-level label
        // (e.g. "newrelic") could target it; skip regex-compiling every other rule.
        let labels: [String] = unbreakExceptions.compactMap {
            let parts = $0.agentHost.split(separator: ".")
            return parts.count >= 2 ? String(parts[parts.count - 2]).lowercased() : parts.first.map { String($0).lowercased() }
        }
        rules = rules.filter { rule in
            guard (rule["action"] as? [String: Any])?["type"] as? String == "block",
                  let filter = (rule["trigger"] as? [String: Any])?["url-filter"] as? String else { return true }
            let lower = filter.lowercased()
            guard labels.contains(where: { lower.contains($0) }),
                  let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) else { return true }
            let blocksAgent = probes.contains { probe in
                regex.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) != nil
            }
            return !blocksAgent
        }
        if includeEndpointBlocks {
            for exception in unbreakExceptions {
                rules.append(["action": ["type": "block"],
                              "trigger": ["url-filter": exception.endpointFilter, "load-type": ["third-party"]]])
            }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let string = String(data: out, encoding: .utf8) else { return json }
        return string
    }

    /// Add `unless-domain: [*host …]` to every rule trigger in a WebKit rule-list JSON array, EXCEPT
    /// rules that already pin `if-domain` (WebKit forbids both in one trigger). A leading `*` makes
    /// each entry match the host and all its subdomains (DNR/WebKit subdomain semantics). With no
    /// hosts the input JSON is returned unchanged.
    nonisolated static func applyExclusions(to json: String, hosts: [String]) -> String {
        guard !hosts.isEmpty,
              let data = json.data(using: .utf8),
              var rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return json }
        // Scope each Shields-off host to its REGISTRABLE DOMAIN (eTLD+1) so blocking is suppressed across the
        // WHOLE site — every subdomain AND every subframe — not just the exact host the user toggled. A
        // site's video player or embedded content frequently lives on a SIBLING subdomain (Edgenuity's
        // player iframe runs on r22.core.learn.edgenuity.com while the page is core.learn.edgenuity.com); a
        // per-exact-host exclusion left those subframes blocked, so the player's trackers (New Relic, GA)
        // stayed blocked and its init died on a cross-origin frame. `*<domain>` matches the domain and all
        // subdomains. Matches how Brave/uBlock scope a per-site shields toggle (the whole registrable site).
        var seen = Set<String>()
        let entries = hosts.compactMap { host -> String? in
            let entry = "*" + Self.registrableDomain(host)
            return seen.insert(entry).inserted ? entry : nil
        }
        for index in rules.indices {
            guard var trigger = rules[index]["trigger"] as? [String: Any] else { continue }
            if trigger["if-domain"] != nil { continue }   // can't combine with unless-domain
            var unless = (trigger["unless-domain"] as? [String]) ?? []
            for entry in entries where !unless.contains(entry) { unless.append(entry) }
            trigger["unless-domain"] = unless
            rules[index]["trigger"] = trigger
        }
        guard let out = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let string = String(data: out, encoding: .utf8) else { return json }
        return string
    }

    /// Two-label public suffixes whose registrable domain is the LAST THREE labels (e.g. `foo.co.uk` →
    /// `foo.co.uk`, not `co.uk`). Covers the common country-code second-level domains so a Shields-off
    /// toggle on such a site doesn't over-broaden to the entire suffix. Not exhaustive (no bundled PSL),
    /// but it catches the cases a user is realistically on; an unknown suffix falls back to last-two.
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "co.jp", "or.jp", "ne.jp", "com.au", "net.au",
        "org.au", "co.nz", "com.br", "com.cn", "com.mx", "co.in", "co.za", "com.tr", "co.kr", "com.sg",
        "com.hk", "com.tw", "co.il", "com.ar", "com.sa", "com.ua", "co.id", "com.my", "com.ph"
    ]

    /// The registrable domain (eTLD+1) of `host` — the scope a per-site Shields toggle should apply to, so
    /// it covers the whole site's subdomains and subframes (Brave/uBlock parity). `r22.core.learn.edgenuity.com`
    /// → `edgenuity.com`; `foo.bar.co.uk` → `bar.co.uk`; a bare host or IP is returned unchanged.
    nonisolated static func registrableDomain(_ host: String) -> String {
        let lower = host.lowercased()
        // Leave IPv4/IPv6 literals (and anything without a dot) untouched.
        guard lower.contains("."), !lower.contains(":"),
              lower.first(where: { !($0.isNumber || $0 == ".") }) != nil else { return lower }
        let labels = lower.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return lower }
        if multiLabelSuffixes.contains(labels.suffix(2).joined(separator: ".")) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }
}
