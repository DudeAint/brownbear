//
//  TabManager.swift
//  BrownBear
//
//  Owns the set of open tabs and which one is active. The browser view controller and the tab
//  grid are both thin views over this model; all create/close/select logic lives here so the
//  two surfaces can never disagree about the tab set.
//

import UIKit
import WebKit

@MainActor
protocol TabManagerDelegate: AnyObject {
    /// The set of tabs changed (a tab was added or removed). `tabs` is the new ordering.
    func tabManager(_ manager: TabManager, didUpdate tabs: [Tab])
    /// The active tab changed. Either side may be nil (no active tab / closed the last one).
    func tabManager(_ manager: TabManager, didActivate tab: Tab?, previous: Tab?)
}

@MainActor
final class TabManager {

    private(set) var tabs: [Tab] = []
    private(set) var activeTabID: UUID?

    weak var delegate: TabManagerDelegate?

    private let configurationFactory: WebViewConfigurationFactory

    init(configurationFactory: WebViewConfigurationFactory) {
        self.configurationFactory = configurationFactory
    }

    // MARK: - Derived

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func tab(for id: UUID) -> Tab? { tabs.first { $0.id == id } }

    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0.id == tab.id } }

    // MARK: - Mutations

    /// Create a new tab, optionally loading a URL and making it active. Returns the new tab.
    @discardableResult
    func createTab(loading url: URL? = nil, activate: Bool = true) -> Tab {
        let tab = Tab(configuration: configurationFactory.makeConfiguration())
        if let url { tab.setPendingURL(url) }
        tabs.append(tab)
        delegate?.tabManager(self, didUpdate: tabs)
        if activate || activeTabID == nil {
            setActiveTab(tab)
        }
        return tab
    }

    /// Create a tab that wraps a configuration WebKit handed us (a `target="_blank"` popup).
    /// The web view must be built from that exact configuration, so we cannot use the factory.
    @discardableResult
    func createTab(adopting configuration: WKWebViewConfiguration, activate: Bool = true) -> Tab {
        let tab = Tab(configuration: configuration)
        tabs.append(tab)
        delegate?.tabManager(self, didUpdate: tabs)
        if activate || activeTabID == nil {
            setActiveTab(tab)
        }
        return tab
    }

    /// Make `tab` the active tab, notifying the delegate of the transition.
    func setActiveTab(_ tab: Tab) {
        guard tab.id != activeTabID else { return }
        let previous = activeTab
        activeTabID = tab.id
        delegate?.tabManager(self, didActivate: tab, previous: previous)
    }

    func selectTab(id: UUID) {
        guard let tab = tab(for: id) else { return }
        setActiveTab(tab)
    }

    /// Close a tab. If it was active, the nearest neighbor becomes active (Chrome behavior:
    /// prefer the tab to the right, then the left). If no tabs remain, active becomes nil.
    func closeTab(id: UUID) {
        guard let removalIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (id == activeTabID)
        let removed = tabs.remove(at: removalIndex)
        removed.stopLoading()
        delegate?.tabManager(self, didUpdate: tabs)

        guard wasActive else { return }
        let previous = removed
        if tabs.isEmpty {
            activeTabID = nil
            delegate?.tabManager(self, didActivate: nil, previous: previous)
        } else {
            let neighbor = tabs[min(removalIndex, tabs.count - 1)]
            activeTabID = neighbor.id
            delegate?.tabManager(self, didActivate: neighbor, previous: previous)
        }
    }

    func closeTab(_ tab: Tab) { closeTab(id: tab.id) }

    /// Close every tab. Used by the "close all" action in the tab grid.
    func closeAll() {
        let previous = activeTab
        tabs.forEach { $0.stopLoading() }
        tabs.removeAll()
        activeTabID = nil
        delegate?.tabManager(self, didUpdate: tabs)
        delegate?.tabManager(self, didActivate: nil, previous: previous)
    }
}
