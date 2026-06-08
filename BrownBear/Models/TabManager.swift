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

    /// A closed normal tab the user can reopen (Safari/Chrome "Recently Closed"). Newest first,
    /// capped. Private tabs are never recorded.
    struct ClosedTabRecord: Equatable { let url: URL; let title: String }
    private(set) var recentlyClosed: [ClosedTabRecord] = []
    private let maxRecentlyClosed = 25

    private let configurationFactory: WebViewConfigurationFactory

    init(configurationFactory: WebViewConfigurationFactory) {
        self.configurationFactory = configurationFactory
    }

    // MARK: - Derived

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }

    /// Tabs split by privacy — the tab grid shows one set at a time (normal / private mode).
    var normalTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [Tab] { tabs.filter { $0.isPrivate } }
    var hasPrivateTabs: Bool { tabs.contains { $0.isPrivate } }

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func tab(for id: UUID) -> Tab? { tabs.first { $0.id == id } }

    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0.id == tab.id } }

    // MARK: - Mutations

    /// Create a new tab, optionally loading a URL and making it active. `isPrivate` selects the
    /// non-persistent (incognito) data store. Returns the new tab.
    @discardableResult
    func createTab(loading url: URL? = nil, activate: Bool = true, isPrivate: Bool = false) -> Tab {
        let tab = Tab(configuration: configurationFactory.makeConfiguration(isPrivate: isPrivate),
                      isPrivate: isPrivate)
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
    /// `isPrivate` should mirror the opener so a popup from a private tab stays private.
    @discardableResult
    func createTab(adopting configuration: WKWebViewConfiguration,
                   activate: Bool = true,
                   isPrivate: Bool = false) -> Tab {
        let tab = Tab(configuration: configuration, isPrivate: isPrivate)
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
        removed.onClose?()
        removed.stopLoading()
        rememberClosed(removed)
        delegate?.tabManager(self, didUpdate: tabs)
        wipePrivateStoreIfNoPrivateTabsRemain(removed: removed)

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
        let hadPrivate = hasPrivateTabs
        let previous = activeTab
        tabs.forEach { $0.onClose?(); $0.stopLoading(); rememberClosed($0) }
        tabs.removeAll()
        activeTabID = nil
        delegate?.tabManager(self, didUpdate: tabs)
        if hadPrivate { wipePrivateDataStore() }
        delegate?.tabManager(self, didActivate: nil, previous: previous)
    }

    /// Close only the tabs of a given privacy (the grid's mode-aware "Close All"). The active tab is
    /// reassigned to a surviving tab if it was among those closed.
    func closeAll(isPrivate: Bool) {
        let toRemove = tabs.filter { $0.isPrivate == isPrivate }
        guard !toRemove.isEmpty else { return }
        let activeWasRemoved = toRemove.contains { $0.id == activeTabID }
        let previous = activeTab
        toRemove.forEach { $0.onClose?(); $0.stopLoading(); rememberClosed($0) }
        tabs.removeAll { $0.isPrivate == isPrivate }
        delegate?.tabManager(self, didUpdate: tabs)
        if isPrivate { wipePrivateDataStore() }

        guard activeWasRemoved else { return }
        if let next = tabs.first {
            activeTabID = next.id
            delegate?.tabManager(self, didActivate: next, previous: previous)
        } else {
            activeTabID = nil
            delegate?.tabManager(self, didActivate: nil, previous: previous)
        }
    }

    /// Close every tab except `id`, which becomes active (the grid's "Close Other Tabs").
    func closeOtherTabs(keeping id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let others = tabs.filter { $0.id != id }
        guard !others.isEmpty else { return }
        let removedPrivate = others.contains { $0.isPrivate }
        let previous = activeTab
        others.forEach { $0.onClose?(); $0.stopLoading(); rememberClosed($0) }
        tabs.removeAll { $0.id != id }
        delegate?.tabManager(self, didUpdate: tabs)
        if removedPrivate, !hasPrivateTabs { wipePrivateDataStore() }
        if activeTabID != id {
            activeTabID = id
            delegate?.tabManager(self, didActivate: tabs.first { $0.id == id }, previous: previous)
        }
    }

    // MARK: - Reordering

    /// Reorder tabs to match the grid's new visible order after a drag. `orderedIDs` is the new order
    /// of one privacy mode's tabs (the grid only ever shows a single mode at a time). Tabs not in the
    /// list — the other mode — keep their relative order. Unknown ids are ignored. Order-only change,
    /// so the active tab and tab count are untouched and no delegate notification is needed (the grid
    /// drives its own animation).
    func reorderTabs(toMatch orderedIDs: [UUID]) {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = orderedIDs.compactMap { byID[$0] }
        guard !reordered.isEmpty else { return }
        let movedIDs = Set(orderedIDs)
        let rest = tabs.filter { !movedIDs.contains($0.id) }
        tabs = reordered + rest
    }

    // MARK: - Recently closed

    /// Record a closed normal tab so it can be reopened. Private tabs leave no trace.
    private func rememberClosed(_ tab: Tab) {
        guard !tab.isPrivate, let url = tab.state.url else { return }
        recentlyClosed.insert(ClosedTabRecord(url: url, title: tab.state.displayTitle), at: 0)
        if recentlyClosed.count > maxRecentlyClosed {
            recentlyClosed.removeLast(recentlyClosed.count - maxRecentlyClosed)
        }
    }

    // MARK: - Private data lifecycle

    /// After closing one tab, wipe the private data store if that tab was the last private one, so a
    /// private session leaves nothing behind.
    private func wipePrivateStoreIfNoPrivateTabsRemain(removed: Tab) {
        guard removed.isPrivate, !hasPrivateTabs else { return }
        wipePrivateDataStore()
    }

    private func wipePrivateDataStore() {
        // Detach synchronously NOW (so a private tab opened in this same run loop gets a fresh store and
        // can't be caught by the wipe), then erase the detached store off the main actor.
        guard let detached = configurationFactory.detachPrivateDataStoreForWipe() else { return }
        Task { await configurationFactory.wipePrivateData(detached) }
    }
}
