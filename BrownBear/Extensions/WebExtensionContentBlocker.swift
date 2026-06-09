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
                var staticRules: [[String: Any]] = []
                for ruleset in manifest.declarativeNetRequest where enabledIDs.contains(ruleset.id) {
                    guard let data = await store.file(extensionID: ext.id, path: ruleset.path),
                          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
                    staticRules.append(contentsOf: arr)
                }
                let dynamicRules = await dnrStore.getDynamicRules(extensionID: ext.id)
                let sessionRules = await dnrStore.getSessionRules(extensionID: ext.id)
                // Nothing to enforce for this extension (no static rulesets AND no runtime rules).
                if staticRules.isEmpty && dynamicRules.isEmpty && sessionRules.isEmpty { continue }

                // Merge so dynamic/session override static by rule id (Chrome precedence), then compile
                // ONE rule list per extension.
                let merged = DeclarativeNetRequestRuleMerge.merge(staticRules: staticRules,
                                                                  dynamicRules: dynamicRules,
                                                                  sessionRules: sessionRules)
                // Extract main-frame redirect rules BEFORE compiling — the content-rule-list compiler
                // .skip()s `redirect`, so an extension whose ONLY rules are redirects compiles to nothing
                // (result.isEmpty → continue below) but its redirect rules must still be applied at nav time.
                newRedirect.append(contentsOf: WebExtensionDNRRedirect.redirectRules(from: merged, extensionID: ext.id))
                let result = DeclarativeNetRequest.compile(rules: merged)
                let identifier = "brownbear-dnr-\(ext.id)"
                guard !result.isEmpty else {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: "(merged)", compiledCount: 0,
                                             skippedCount: result.skippedCount,
                                             error: result.warnings.first ?? "no rules compiled"))
                    continue
                }
                // Exclude shields-off hosts from every extension rule that can carry an exclusion
                // (a rule already pinned with `if-domain` can't also take `unless-domain`, so it is
                // left unchanged — BrownBear's built-in list still honors the shields-off host).
                let scopedJSON = Self.applyExclusions(to: result.json, hosts: exclusions)
                do {
                    let list = try await compile(store: ruleListStore, identifier: identifier, json: scopedJSON)
                    compiledLists.append(list)
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: "(merged)", compiledCount: result.compiledCount,
                                             skippedCount: result.skippedCount, error: nil))
                } catch {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: "(merged)", compiledCount: 0,
                                             skippedCount: result.skippedCount,
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
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? BrownBearError.bridgeRejected("rule-list compile failed"))
                }
            }
        }
    }

    /// Compile BrownBear's built-in tracker/ad list with the shields-off hosts excluded. Returns nil
    /// (and installs nothing) if the bundled list is missing or fails to compile — a built-in-list
    /// failure must never take the extension lists down with it.
    private func compileBuiltInList(excluding hosts: [String]) async -> WKContentRuleList? {
        guard let ruleListStore, let json = Self.builtInBlocklistJSON(excluding: hosts) else { return nil }
        return try? await compile(store: ruleListStore, identifier: "brownbear-builtin-blocklist", json: json)
    }

    // MARK: - Built-in list + per-site exclusions (pure helpers, unit-testable)

    /// BrownBear's bundled tracker/ad blocklist, already in WebKit content-rule-list JSON, with the
    /// shields-off hosts injected as a global `unless-domain` so blocking is suppressed there. Returns
    /// nil if the bundled resource is missing or empty (then no built-in list is installed).
    static func builtInBlocklistJSON(excluding hosts: [String]) -> String? {
        // Prefer the network-updated merged list (EasyList/EasyPrivacy/Peter Lowe — uBlock-style, kept
        // fresh by ContentBlocklistUpdater); fall back to the small bundled starter list offline / on
        // first launch before the first successful fetch.
        var json: String? = ContentBlocklistUpdater.shared.cachedMergedJSON
        if json == nil {
            if let url = Bundle.main.url(forResource: "brownbear-blocklist", withExtension: "json", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-blocklist", withExtension: "json", subdirectory: "JS"),
               let data = try? Data(contentsOf: url) {
                json = String(data: data, encoding: .utf8)
            }
        }
        guard let json else { return nil }
        let unbroken = appendUnbreakRules(to: json)
        let scoped = applyExclusions(to: unbroken, hosts: hosts)
        return scoped == "[]" ? nil : scoped
    }

    /// A telemetry SCRIPT that BREAKS the page when blocked, paired with the data ENDPOINT that carries
    /// its actual tracking payload. New Relic is the canonical case: its inline page snippet wraps
    /// `window.addEventListener` with a thunk that delegates to a reference only the external agent
    /// (`js-agent.newrelic.com`) initializes — so blocking the agent leaves that thunk throwing
    /// "addEventListener is not a function", poisoning the page's own global and taking down every
    /// MAIN-world script on the page (the page's code AND any userscript). Blocking the data endpoint
    /// (`nr-data.net`) instead stops the telemetry from ever leaving, with no page breakage.
    private struct UnbreakException {
        let allowFilter: String   // the breakage-prone SCRIPT to let load (un-blocked)
        let blockFilter: String   // its data-collection ENDPOINT to keep blocked
    }
    private static let unbreakExceptions: [UnbreakException] = [
        UnbreakException(allowFilter: "^https?://([^/]+\\.)?js-agent\\.newrelic\\.com[:/]",
                         blockFilter: "^https?://([^/]+\\.)?nr-data\\.net[:/]")
    ]

    /// Rewrite the merged built-in list so a breakage-prone telemetry script LOADS (page stays intact)
    /// while its data endpoint stays BLOCKED. Implemented in-list: an `ignore-previous-rules` action
    /// un-does any earlier block of the script (WebKit applies it only within the SAME rule list, which
    /// is exactly where the upstream block lives — the merged built-in list), and an explicit third-party
    /// `block` of the data endpoint guarantees the telemetry is dropped even if the upstream list didn't
    /// already cover it. Appended LAST so the ignore overrides the upstream block. Fails safe: a JSON it
    /// can't parse is returned unchanged. Pure — unit-tested directly.
    static func appendUnbreakRules(to json: String) -> String {
        guard let data = json.data(using: .utf8),
              var rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return json }
        for exception in unbreakExceptions {
            rules.append(["action": ["type": "block"],
                          "trigger": ["url-filter": exception.blockFilter, "load-type": ["third-party"]]])
            rules.append(["action": ["type": "ignore-previous-rules"],
                          "trigger": ["url-filter": exception.allowFilter]])
        }
        guard let out = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let string = String(data: out, encoding: .utf8) else { return json }
        return string
    }

    /// Add `unless-domain: [*host …]` to every rule trigger in a WebKit rule-list JSON array, EXCEPT
    /// rules that already pin `if-domain` (WebKit forbids both in one trigger). A leading `*` makes
    /// each entry match the host and all its subdomains (DNR/WebKit subdomain semantics). With no
    /// hosts the input JSON is returned unchanged.
    static func applyExclusions(to json: String, hosts: [String]) -> String {
        guard !hosts.isEmpty,
              let data = json.data(using: .utf8),
              var rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return json }
        let entries = hosts.map { "*" + $0 }
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
}
