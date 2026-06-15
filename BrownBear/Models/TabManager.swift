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

    /// User-defined tab groups (Safari-style named groups), loaded at launch and persisted on every
    /// change. Group MEMBERSHIP lives on each `Tab.groupID`; this holds the group definitions (name +
    /// color), in display order. Private tabs are never grouped.
    private(set) var groups: [TabGroup] = TabGroupStore.load()

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

    /// Replace `old` with a new tab built from `configuration`, **in place** — preserving its position,
    /// pinned state, and group membership, and transferring active selection if `old` was active. Used by
    /// session restore to upgrade an extension placeholder into the real chrome-extension page tab it
    /// can't be created as up front (a normal tab can't host that scheme; the page session is built
    /// asynchronously). This is an internal swap, NOT a user close, so it records no recently-closed entry.
    /// Returns the new tab, or nil if `old` is no longer present (e.g. the user closed it meanwhile).
    @discardableResult
    func replaceTab(_ old: Tab, adopting configuration: WKWebViewConfiguration) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == old.id }) else { return nil }
        let wasActive = (old.id == activeTabID)
        let new = Tab(configuration: configuration, isPrivate: old.isPrivate)
        new.isPinned = old.isPinned
        new.groupID = old.groupID
        tabs[index] = new
        old.onClose?()
        old.stopLoading()
        delegate?.tabManager(self, didUpdate: tabs)
        if wasActive {
            activeTabID = new.id
            delegate?.tabManager(self, didActivate: new, previous: old)
        }
        return new
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

    // MARK: - Tab groups

    /// The group definition for an id (nil id or unknown id → nil).
    func group(for id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// The (ordered) tabs that belong to a group, scoped to normal tabs (private tabs are never grouped).
    func tabs(inGroup id: UUID) -> [Tab] { normalTabs.filter { $0.groupID == id } }

    /// How many normal tabs are in a group — for the group switcher's count badges.
    func tabCount(inGroup id: UUID) -> Int { normalTabs.reduce(0) { $0 + ($1.groupID == id ? 1 : 0) } }

    /// Create a new group. The color defaults to the next palette color so back-to-back groups differ.
    @discardableResult
    func createGroup(name: String, color: TabGroupColor? = nil) -> TabGroup {
        let group = TabGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Group" : name,
                             color: color ?? TabGroupColor.suggested(forExistingCount: groups.count))
        groups.append(group)
        TabGroupStore.save(groups)
        return group
    }

    func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[index].name = trimmed
        TabGroupStore.save(groups)
    }

    func recolorGroup(id: UUID, to color: TabGroupColor) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].color = color
        TabGroupStore.save(groups)
    }

    /// Delete a group. Its tabs stay open, just ungrouped.
    func deleteGroup(id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        TabGroupStore.save(groups)
        persistSession()
    }

    /// Assign a tab to a group (pass nil to ungroup). Private tabs are never grouped. Persists the change.
    func setGroup(_ groupID: UUID?, forTab tabID: UUID) {
        guard let tab = tab(for: tabID), !tab.isPrivate else { return }
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return }   // ignore unknown group
        tab.groupID = groupID
        persistSession()
    }

    /// Apply a persisted group membership to an already-restored tab (called by the browser's restore
    /// loop). Drops the membership if its group no longer exists or the tab is private.
    func restoreGroupMembership(_ groupID: UUID?, forTab tab: Tab) {
        guard let groupID, !tab.isPrivate, groups.contains(where: { $0.id == groupID }) else {
            tab.groupID = nil
            return
        }
        tab.groupID = groupID
    }

    // MARK: - Session persistence

    /// Persist the current NORMAL tabs (url + title, in order) and which one is active, so they're
    /// restored after the app closes. Private tabs are excluded (incognito leaves no trace). A tab still
    /// on the New Tab page (or one restored-but-not-yet-loaded) keeps its pending URL so the right page
    /// comes back. Cheap; call on app background and after structural tab changes.
    func persistSession() {
        let normals = normalTabs
        let records = normals.map { tab in
            TabSessionStore.Record(url: (tab.pendingURL ?? tab.state.url)?.absoluteString,
                                   title: tab.state.displayTitle,
                                   id: tab.id.uuidString,
                                   isPinned: tab.isPinned,
                                   groupID: tab.groupID?.uuidString)
        }
        // Persist each tab's thumbnail (best-effort) so the grid shows a preview after relaunch, and drop
        // snapshots for tabs no longer open so the cache can't grow without bound.
        for tab in normals {
            if let snapshot = tab.snapshot { TabSnapshotStore.save(snapshot, id: tab.id.uuidString) }
        }
        TabSnapshotStore.prune(keeping: Set(normals.map { $0.id.uuidString }))
        let activeIndex = activeTab.flatMap { active in normals.firstIndex { $0.id == active.id } }
        TabSessionStore.save(records: records, activeIndex: activeIndex)
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
