//
//  WebExtensionContextMenuStore.swift
//  BrownBear
//
//  The native source of truth for `chrome.contextMenus` / `browser.menus` items, per extension. iOS
//  has no persistent toolbar/right-click menu, so registered items surface in WebKit's element
//  long-press menu (link/image) — see BrownBearBrowserViewController+ContextMenus. content scripts,
//  popups, and background workers all register through here (router + background dispatch), so every
//  surface shares one coherent item set.
//
//  Threading: @MainActor — the menu UI and the (MainActor) routers touch it, and the background worker
//  reaches it only after hopping to the main actor (see WebExtensionBackgroundContext+ContextMenus).
//
//  Trust boundary (CLAUDE.md §5): every property arrives from untrusted JS. Types/contexts/parents/
//  patterns are sanitized and fail closed (an unknown type → normal, an unknown/cyclic parent → root,
//  an unknown context → dropped, defaulting to ["page"]). Per-extension item counts are capped so a
//  runaway worker can't exhaust memory across the shared, app-lifetime store.
//

import Foundation

extension Notification.Name {
    /// Posted (main thread) whenever an extension's context-menu items change, so any open UI can
    /// refresh. userInfo: `extensionID: String`. (The long-press menu is built on demand, so this is
    /// mostly for completeness / future surfaces.)
    static let brownBearExtensionContextMenuDidChange = Notification.Name("brownBearExtensionContextMenuDidChange")
}

@MainActor
final class WebExtensionContextMenuStore {

    static let didChangeNotification = Notification.Name.brownBearExtensionContextMenuDidChange

    // MARK: - Model

    enum ItemType: String {
        case normal, checkbox, radio, separator
    }

    /// One registered menu item. `contexts` are the Chrome context strings (we only ever match page/
    /// link/image on iOS); `documentURLPatterns`/`targetURLPatterns` are match-pattern globs.
    struct Item {
        let id: String
        var title: String
        var type: ItemType
        var checked: Bool
        var enabled: Bool
        var visible: Bool
        var contexts: Set<String>
        var parentID: String?
        var documentURLPatterns: [String]
        var targetURLPatterns: [String]
    }

    /// A resolved item plus its applicable children, for the browser to render as a UIMenu tree.
    struct ResolvedItem {
        let item: Item
        let children: [ResolvedItem]
    }

    // MARK: - Caps

    /// Max items one extension may register, oldest dropped beyond it (fail-closed memory bound).
    private static let maxItemsPerExtension = 1000
    private static let maxTitleLength = 200
    private static let maxPatterns = 100

    /// The Chrome context strings we accept. Unknowns are dropped (fail closed). On iOS only
    /// page/link/image can ever match, but we store the rest faithfully so create/update round-trips.
    private static let knownContexts: Set<String> = [
        "all", "page", "frame", "selection", "link", "editable",
        "image", "video", "audio", "launcher", "browser_action", "page_action", "action"
    ]

    /// extensionID → items, in creation order (the order the long-press menu renders them).
    private var itemsByExtension: [String: [Item]] = [:]

    // MARK: - Create / update / remove

    /// Register a new item. Returns its id (caller-supplied or generated). Throws if a caller-supplied
    /// id duplicates an existing one (Chrome's contract) or a separator has children semantics violated.
    @discardableResult
    func create(extensionID: String, properties: [String: Any]) throws -> String {
        var items = itemsByExtension[extensionID] ?? []
        let id = Self.itemID(properties["id"]) ?? "bbcm_\(extensionID.prefix(4))_\(items.count)_\(Self.nextSeq())"
        if items.contains(where: { $0.id == id }) {
            throw BrownBearError.bridgeRejected("a context-menu item with id '\(id)' already exists")
        }
        let type = Self.sanitizeType(properties["type"])
        let item = Item(
            id: id,
            title: Self.sanitizeTitle(properties["title"], type: type),
            type: type,
            checked: (properties["checked"] as? Bool) ?? false,
            enabled: (properties["enabled"] as? Bool) ?? true,
            visible: (properties["visible"] as? Bool) ?? true,
            contexts: Self.sanitizeContexts(properties["contexts"]),
            parentID: Self.sanitizeParent(properties["parentId"], in: items, itemID: id),
            documentURLPatterns: Self.sanitizePatterns(properties["documentUrlPatterns"]),
            targetURLPatterns: Self.sanitizePatterns(properties["targetUrlPatterns"]))
        items.append(item)
        if item.type == .radio && item.checked {
            Self.clearRadioSiblings(&items, of: item, exceptID: id)
        }
        Self.enforceCap(&items)
        itemsByExtension[extensionID] = items
        postChange(extensionID)
        return id
    }

    /// Apply only the supplied properties to an existing item (Chrome's update merges). Throws if the
    /// id is unknown.
    func update(extensionID: String, id: String, properties: [String: Any]) throws {
        guard var items = itemsByExtension[extensionID],
              let index = items.firstIndex(where: { $0.id == id }) else {
            throw BrownBearError.bridgeRejected("no context-menu item with id '\(id)'")
        }
        var item = items[index]
        if properties.keys.contains("type") { item.type = Self.sanitizeType(properties["type"]) }
        if properties.keys.contains("title") { item.title = Self.sanitizeTitle(properties["title"], type: item.type) }
        if let checked = properties["checked"] as? Bool { item.checked = checked }
        if let enabled = properties["enabled"] as? Bool { item.enabled = enabled }
        if let visible = properties["visible"] as? Bool { item.visible = visible }
        if properties.keys.contains("contexts") { item.contexts = Self.sanitizeContexts(properties["contexts"]) }
        if properties.keys.contains("parentId") {
            item.parentID = Self.sanitizeParent(properties["parentId"], in: items, itemID: id)
        }
        if properties.keys.contains("documentUrlPatterns") {
            item.documentURLPatterns = Self.sanitizePatterns(properties["documentUrlPatterns"])
        }
        if properties.keys.contains("targetUrlPatterns") {
            item.targetURLPatterns = Self.sanitizePatterns(properties["targetUrlPatterns"])
        }
        items[index] = item
        if item.type == .radio && item.checked {
            Self.clearRadioSiblings(&items, of: item, exceptID: id)
        }
        itemsByExtension[extensionID] = items
        postChange(extensionID)
    }

    /// Remove an item and its entire descendant subtree (Chrome removes children with the parent).
    func remove(extensionID: String, id: String) throws {
        guard var items = itemsByExtension[extensionID],
              items.contains(where: { $0.id == id }) else {
            throw BrownBearError.bridgeRejected("no context-menu item with id '\(id)'")
        }
        let doomed = Self.subtreeIDs(rootID: id, in: items)
        items.removeAll { doomed.contains($0.id) }
        itemsByExtension[extensionID] = items
        postChange(extensionID)
    }

    func removeAll(extensionID: String) {
        guard itemsByExtension[extensionID]?.isEmpty == false else { return }
        itemsByExtension[extensionID] = []
        postChange(extensionID)
    }

    /// Drop an extension's items entirely (uninstall/disable). No notification — the extension is gone.
    func forgetExtension(_ extensionID: String) {
        itemsByExtension.removeValue(forKey: extensionID)
    }

    // MARK: - Query (for the long-press menu)

    /// Extensions that currently have ANY items registered, so the browser can skip building menus for
    /// the rest.
    func extensionIDsWithItems() -> [String] {
        itemsByExtension.compactMap { $0.value.isEmpty ? nil : $0.key }
    }

    /// The applicable item tree for an extension at a long-press point: top-level visible items whose
    /// context + URL patterns match, each with its applicable children. `contexts` is what's available
    /// at the press (always `page`, plus `link`/`image` when present).
    func applicableTree(extensionID: String, pageURL: String, linkURL: String?,
                        contexts: Set<String>) -> [ResolvedItem] {
        guard let items = itemsByExtension[extensionID], !items.isEmpty else { return [] }
        let byParent = Dictionary(grouping: items, by: { $0.parentID ?? "" })
        func build(parentKey: String) -> [ResolvedItem] {
            (byParent[parentKey] ?? []).compactMap { item in
                guard applies(item, pageURL: pageURL, linkURL: linkURL, available: contexts) else { return nil }
                let children = build(parentKey: item.id)
                // A parent that matched only because of children with no own action is still shown;
                // a separator/parent with no matching children but matching context still shows.
                return ResolvedItem(item: item, children: children)
            }
        }
        return build(parentKey: "")
    }

    func hasApplicableItems(extensionID: String, pageURL: String, linkURL: String?,
                            contexts: Set<String>) -> Bool {
        !applicableTree(extensionID: extensionID, pageURL: pageURL, linkURL: linkURL, contexts: contexts).isEmpty
    }

    /// The OnClickData object Chrome passes to onClicked, built from the tapped item + press context.
    func onClickData(item: Item, pageURL: String, linkURL: String?) -> [String: Any] {
        var info: [String: Any] = [
            "menuItemId": item.id,
            "editable": false,
            "pageUrl": pageURL
        ]
        if let parentID = item.parentID { info["parentMenuItemId"] = parentID }
        if let linkURL, !linkURL.isEmpty, item.contexts.contains("link") || item.contexts.contains("all") {
            info["linkUrl"] = linkURL
        }
        if item.type == .checkbox || item.type == .radio {
            // onClickData is built BEFORE applyClickStateChange, so item.checked is the OLD state;
            // `checked` reports the NEW state a tap produces (a radio always becomes checked).
            info["wasChecked"] = item.checked
            info["checked"] = item.type == .radio ? true : !item.checked
        }
        return info
    }

    /// Apply the check-state change a tap implies (checkbox toggles; radio selects + clears siblings).
    /// Returns the new checked state, or nil for a normal/separator item. Mutates the store + posts.
    @discardableResult
    func applyClickStateChange(extensionID: String, id: String) -> Bool? {
        guard var items = itemsByExtension[extensionID],
              let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        switch items[index].type {
        case .checkbox:
            items[index].checked.toggle()
        case .radio:
            items[index].checked = true
            Self.clearRadioSiblings(&items, of: items[index], exceptID: id)
        case .normal, .separator:
            return nil
        }
        let newValue = items[index].checked
        itemsByExtension[extensionID] = items
        postChange(extensionID)
        return newValue
    }

    /// Look up a single item (the browser keeps an id from the tapped UIAction).
    func item(extensionID: String, id: String) -> Item? {
        itemsByExtension[extensionID]?.first { $0.id == id }
    }

    // MARK: - Matching

    private func applies(_ item: Item, pageURL: String, linkURL: String?, available: Set<String>) -> Bool {
        guard item.visible else { return false }   // separators are kept (they render as dividers)
        // Context match: "all" matches any available; otherwise the item's contexts must intersect what
        // the press offers. A "page" item matches every press (Chrome shows page items on links too).
        let itemContexts = item.contexts.contains("all")
            ? Self.knownContexts
            : item.contexts
        let contextOK = itemContexts.contains("page") || !itemContexts.isDisjoint(with: available)
        guard contextOK else { return false }
        // documentUrlPatterns gate on the page URL.
        if !item.documentURLPatterns.isEmpty {
            guard Self.matcher(item.documentURLPatterns).matches(pageURL) else { return false }
        }
        // targetUrlPatterns gate on the link target (only meaningful when there is a link).
        if !item.targetURLPatterns.isEmpty {
            guard let linkURL, !linkURL.isEmpty,
                  Self.matcher(item.targetURLPatterns).matches(linkURL) else { return false }
        }
        return true
    }

    private static func matcher(_ patterns: [String]) -> URLMatcher {
        URLMatcher(matches: patterns, includes: [], excludes: [], excludeMatches: [])
    }

    // MARK: - Sanitizers (fail closed)

    private static func sanitizeType(_ value: Any?) -> ItemType {
        guard let raw = value as? String, let type = ItemType(rawValue: raw) else { return .normal }
        return type
    }

    private static func sanitizeTitle(_ value: Any?, type: ItemType) -> String {
        if type == .separator { return "" }
        let raw = (value as? String) ?? ""
        return raw.count > maxTitleLength ? String(raw.prefix(maxTitleLength)) + "\u{2026}" : raw
    }

    private static func sanitizeContexts(_ value: Any?) -> Set<String> {
        guard let array = value as? [Any] else { return ["page"] }
        let parsed = Set(array.compactMap { $0 as? String }.filter { knownContexts.contains($0) })
        return parsed.isEmpty ? ["page"] : parsed
    }

    /// A parent id is accepted only if it names an existing item AND introducing it doesn't create a
    /// cycle (the would-be parent's ancestry must not include this item). Otherwise the item is a root.
    private static func sanitizeParent(_ value: Any?, in items: [Item], itemID: String) -> String? {
        guard let parentID = itemID(value), parentID != itemID,
              items.contains(where: { $0.id == parentID }) else { return nil }
        // Walk up from parentID; if we reach itemID, it's a cycle — reject.
        var cursor: String? = parentID
        var hops = 0
        while let current = cursor, hops < items.count + 1 {
            if current == itemID { return nil }
            cursor = items.first(where: { $0.id == current })?.parentID
            hops += 1
        }
        return parentID
    }

    private static func sanitizePatterns(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return Array(array.compactMap { $0 as? String }.prefix(maxPatterns))
    }

    private static func itemID(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let int = value as? Int { return String(int) }
        return nil
    }

    // MARK: - Helpers

    /// Every id in the subtree rooted at `rootID` (inclusive), so remove() takes children with it.
    private static func subtreeIDs(rootID: String, in items: [Item]) -> Set<String> {
        var doomed: Set<String> = [rootID]
        var changed = true
        while changed {
            changed = false
            for item in items where item.parentID.map({ doomed.contains($0) }) == true && !doomed.contains(item.id) {
                doomed.insert(item.id)
                changed = true
            }
        }
        return doomed
    }

    /// Clear `checked` on every OTHER radio item sharing the same parent group as `item`.
    private static func clearRadioSiblings(_ items: inout [Item], of item: Item, exceptID: String) {
        for index in items.indices where items[index].id != exceptID
            && items[index].type == .radio
            && items[index].parentID == item.parentID {
            items[index].checked = false
        }
    }

    private static func enforceCap(_ items: inout [Item]) {
        while items.count > maxItemsPerExtension { items.removeFirst() }
    }

    private static var seq = 0
    private static func nextSeq() -> Int { seq += 1; return seq }

    private func postChange(_ extensionID: String) {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil,
                                        userInfo: ["extensionID": extensionID])
    }
}
