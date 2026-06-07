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
        return tabs.map(tabRecord)
    }

    func webExtTab(extTabId: Int?) -> [String: Any]? {
        resolveTab(extTabId).map(tabRecord)
    }

    func webExtCreateTab(url: String?, active: Bool) -> [String: Any] {
        let target = url.flatMap(Self.navigableURL)
        let tab = tabManager.createTab(loading: target, activate: active)
        tab.delegate = self
        if target == nil {
            loadNewTabPage(in: tab)
        } else {
            tab.loadPendingURLIfNeeded()
        }
        return tabRecord(tab)
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
        return tabRecord(tab)
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

    // MARK: - Helpers

    /// The chrome.tabs Tab record for a tab (single-window, so windowId is always 1).
    private func tabRecord(_ tab: Tab) -> [String: Any] {
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
