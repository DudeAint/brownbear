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
    private let ruleListStore: WKContentRuleListStore?
    private(set) var reports: [Report] = []

    init(store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         ruleListStore: WKContentRuleListStore? = WKContentRuleListStore.default()) {
        self.store = store
        self.ruleListStore = ruleListStore
    }

    /// Total rules currently enforced across all installed extensions (for the dashboard summary).
    var activeRuleCount: Int { reports.reduce(0) { $0 + $1.compiledCount } }

    /// Recompile every enabled extension's enabled DNR rulesets and install them into the shared
    /// content controller, replacing whatever was there. Idempotent; safe to call on any change.
    func refresh(into userContentController: WKUserContentController) async {
        userContentController.removeAllContentRuleLists()
        var newReports: [Report] = []

        guard let ruleListStore else {
            reports = []
            return
        }

        for ext in await store.enabledExtensions() {
            guard let manifest = ext.manifest, !manifest.declarativeNetRequest.isEmpty else { continue }
            for ruleset in manifest.declarativeNetRequest where ruleset.enabled {
                let identifier = "brownbear-dnr-\(ext.id)-\(ruleset.id)"

                guard let data = await store.file(extensionID: ext.id, path: ruleset.path) else {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: ruleset.id, compiledCount: 0, skippedCount: 0,
                                             error: "ruleset file '\(ruleset.path)' not found"))
                    continue
                }

                let result = DeclarativeNetRequest.compile(rulesetData: data)
                guard !result.isEmpty else {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: ruleset.id, compiledCount: 0,
                                             skippedCount: result.skippedCount,
                                             error: result.warnings.first ?? "no rules compiled"))
                    continue
                }

                do {
                    let list = try await compile(store: ruleListStore, identifier: identifier, json: result.json)
                    userContentController.add(list)
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: ruleset.id, compiledCount: result.compiledCount,
                                             skippedCount: result.skippedCount, error: nil))
                } catch {
                    newReports.append(Report(extensionID: ext.id, extensionName: ext.displayName,
                                             rulesetID: ruleset.id, compiledCount: 0,
                                             skippedCount: result.skippedCount,
                                             error: error.localizedDescription))
                }
            }
        }
        reports = newReports
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
}
