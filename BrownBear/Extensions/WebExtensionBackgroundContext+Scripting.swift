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
            let matcher = URLMatcher(matches: manifest.effectiveHostPatterns,
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
}
