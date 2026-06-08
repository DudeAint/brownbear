//
//  BrownBearBrowserViewController+WebExtensions.swift
//  BrownBear
//
//  The browser's implementation of WebExtensionBridgeHost — chrome.tabs over TabManager. Tab records
//  use the chrome shape (integer id from the registry, windowId 1 — iOS is single-window). Split into
//  its own file to keep the controller under the SwiftLint length limit; the members it touches
//  (tabManager, webExtTabRegistry, loadNewTabPage) are internal for cross-file access.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController: WebExtensionBridgeHost {

    func webExtQueryTabs(_ query: [String: Any]) -> [[String: Any]] {
        var tabs = tabManager.tabs
        if let active = query["active"] as? Bool {
            tabs = tabs.filter { ($0.id == tabManager.activeTabID) == active }
        }
        if let incognito = query["incognito"] as? Bool {
            tabs = tabs.filter { $0.isPrivate == incognito }
        }
        let patterns = urlPatterns(from: query["url"])
        if !patterns.isEmpty {
            let matcher = URLMatcher(matches: patterns, includes: [], excludes: [], excludeMatches: [])
            tabs = tabs.filter { tab in tab.state.url.map { matcher.matches($0.absoluteString) } ?? false }
        }
        return tabs.map(webExtTabRecord)
    }

    func webExtTab(extTabId: Int?) -> [String: Any]? {
        resolveTab(extTabId).map(webExtTabRecord)
    }

    func webExtCreateTab(url: String?, active: Bool) -> [String: Any] {
        // A chrome-extension://<id>/<path> URL needs the per-extension scheme handler + chrome.* page
        // bridge a normal tab lacks (else it loads blank). Route it to the real extension-page tab. The
        // target extension is the URL's host; resolving it is async (the store is an actor), so we kick
        // it off and return a provisional record (chrome.tabs.create's result; callers rarely need the id).
        if let url, let parsed = URL(string: url),
           parsed.scheme == WebExtensionSchemeHandler.scheme,
           let extID = parsed.host, ChromeWebStore.isExtensionID(extID) {
            var path = parsed.path
            while path.hasPrefix("/") { path.removeFirst() }
            Task { @MainActor in
                guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extID) else { return }
                openExtensionPageTab(ext: ext, kind: .options, path: path.isEmpty ? nil : path, activate: active)
            }
            return ["id": -1, "url": url, "active": active, "windowId": Self.webExtWindowID, "index": tabManager.count]
        }
        let target = url.flatMap(Self.navigableURL)
        let tab = tabManager.createTab(loading: target, activate: active)
        tab.delegate = self
        if target == nil {
            loadNewTabPage(in: tab)
        } else {
            tab.loadPendingURLIfNeeded()
        }
        return webExtTabRecord(tab)
    }

    func webExtUpdateTab(extTabId: Int?, url: String?, active: Bool?) -> [String: Any]? {
        guard let tab = resolveTab(extTabId) else { return nil }
        if let target = url.flatMap(Self.navigableURL) {
            tab.delegate = self
            tab.load(target)
        }
        if active == true {
            tabManager.setActiveTab(tab)
        }
        return webExtTabRecord(tab)
    }

    func webExtRemoveTabs(extTabIds: [Int]) {
        for extID in extTabIds {
            guard let uuid = webExtTabRegistry.uuid(for: extID) else { continue }
            tabManager.closeTab(id: uuid)
            webExtTabRegistry.forget(uuid: uuid)
        }
    }

    func webExtReloadTab(extTabId: Int?, bypassCache: Bool) {
        resolveTab(extTabId)?.reload()
    }

    // MARK: - chrome.scripting

    func webExtExecuteScript(extTabId: Int?, world: String, code: String) async -> [[String: Any]] {
        guard let tab = resolveTab(extTabId) else { return [] }
        let contentWorld: WKContentWorld = (world.uppercased() == "MAIN") ? .page : injection.contentWorld
        let value: Any? = await withCheckedContinuation { continuation in
            BBEvaluateJavaScriptForResult(tab.webView, code, contentWorld) { result, _ in
                continuation.resume(returning: result)
            }
        }
        // One frame on iOS (the main frame); chrome's shape is an array of InjectionResult.
        return [["result": value ?? NSNull(), "frameId": 0]]
    }

    func webExtInsertCSS(extTabId: Int?, css: String) {
        guard let tab = resolveTab(extTabId) else { return }
        let literal = Self.jsStringLiteral(css)
        let js = "(function(){var s=document.createElement('style');"
            + "s.setAttribute('data-brownbear-ext-css','1');s.textContent=\(literal);"
            + "(document.head||document.documentElement).appendChild(s);})()"
        BBEvaluateJavaScript(tab.webView, js, .page)
    }

    func webExtRemoveCSS(extTabId: Int?, css: String) {
        guard let tab = resolveTab(extTabId) else { return }
        let literal = Self.jsStringLiteral(css)
        let js = "(function(){var c=\(literal);"
            + "var styles=document.querySelectorAll('style[data-brownbear-ext-css=\"1\"]');"
            + "for(var i=0;i<styles.length;i++){if(styles[i].textContent===c){styles[i].remove();}}})()"
        BBEvaluateJavaScript(tab.webView, js, .page)
    }

    // MARK: - chrome.tabs.sendMessage

    func webExtSendMessageToTab(extensionID: String, extTabId: Int?, message: Any, frameId: Int?) async -> Any? {
        guard let tab = resolveTab(extTabId) else { return nil }
        // The shared content router (on InjectionOrchestrator) owns the content sessions for this tab,
        // so delivery flows through it regardless of which surface (popup/background/content) sent the
        // message — each of those has its own router with no content sessions of its own.
        return await injection.webExtSendMessageToTab(extensionID: extensionID,
                                                      webView: tab.webView,
                                                      message: message,
                                                      frameId: frameId)
    }

    // MARK: - Helpers

    /// Encode a Swift string as a safe JS string literal (quotes included) via JSON.
    private static func jsStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string], options: []),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        // json is `["...escaped..."]`; strip the surrounding brackets to get the bare string literal.
        return String(json.dropFirst().dropLast())
    }

    /// The chrome.tabs Tab record for a tab (single-window, so windowId is always 1).
    func webExtTabRecord(_ tab: Tab) -> [String: Any] {
        let index = tabManager.tabs.firstIndex { $0.id == tab.id } ?? 0
        let isActive = tab.id == tabManager.activeTabID
        return [
            "id": webExtTabRegistry.id(for: tab.id),
            "index": index,
            "windowId": 1,
            "active": isActive,
            "highlighted": isActive,
            "selected": isActive,
            "pinned": false,
            "audible": false,
            "discarded": false,
            "incognito": tab.isPrivate,
            "url": tab.state.url?.absoluteString ?? "",
            "title": tab.state.displayTitle,
            "status": tab.state.isLoading ? "loading" : "complete"
        ]
    }

    /// Resolve a chrome tab id to a Tab; `nil` means the active tab (chrome's default for most APIs).
    private func resolveTab(_ extTabId: Int?) -> Tab? {
        guard let extTabId else { return tabManager.activeTab }
        guard let uuid = webExtTabRegistry.uuid(for: extTabId) else { return nil }
        return tabManager.tab(for: uuid)
    }

    private func urlPatterns(from value: Any?) -> [String] {
        if let single = value as? String { return [single] }
        if let many = value as? [String] { return many }
        return []
    }

    /// Only navigate to http(s)/about — never let an extension drive the browser to file:// etc.
    private static func navigableURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else { return nil }
        return url
    }
}
