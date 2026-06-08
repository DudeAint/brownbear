//
//  WebExtensionActionState.swift
//  BrownBear
//
//  The native source of truth for `chrome.action` / `chrome.browserAction` UI state — badge text,
//  badge color, title, icon, popup path, and enabled flag — per extension, with an optional per-tab
//  override layer (Chrome lets `setBadgeText({ text, tabId })` etc. scope to one tab). The browser's
//  overflow-menu action entries read from here, and the chrome.* bridge writes to it from content
//  scripts, popups, and background workers alike, so every surface sees one coherent state.
//
//  Threading: @MainActor — the menu UI and the (MainActor) message router both touch it, and the
//  background context reaches it only after hopping to the main actor (see WebExtensionBackground
//  Context's action native). Defaults are persisted so a restart keeps a user-visible badge; per-tab
//  overrides are session-only (tab ids don't survive a relaunch), matching Chrome.
//

import UIKit

@MainActor
final class WebExtensionActionState {

    /// Posted (main thread) whenever any action property changes, so the browser's overflow menu can
    /// re-render its per-extension action entries (badge text/color, title, enabled). userInfo:
    /// `extensionID: String` and, when the change was tab-scoped, `tabId: Int`.
    static let didChangeNotification = Notification.Name("brownBearExtensionActionDidChange")

    /// The resolved, displayable state of one extension's action for one tab — defaults overlaid with
    /// any per-tab overrides. This is what the menu renders and what `get*` calls return.
    struct Resolved {
        var badgeText: String
        var badgeColor: String      // CSS-ish "#rrggbb" / "#rrggbbaa"
        var title: String
        var popup: String?          // resolved popup path ("" disables it; nil = use manifest default)
        var iconPath: String?       // chosen icon path, if any
        var enabled: Bool
    }

    /// One layer of action properties. `nil` means "inherit from the layer below" (tab → default →
    /// manifest), so a `setBadgeText({ tabId })` doesn't clobber the global title and vice-versa.
    /// `fileprivate` (not `private`) so the same-file LayerCodable mirror + the Layer extension below
    /// can reach it — `private` confines a nested type to the enclosing class's own body.
    fileprivate struct Layer {
        var badgeText: String?
        var badgeColor: String?
        var title: String?
        var popup: String?
        var iconPath: String?
        var enabled: Bool?
    }

    /// Per-extension default layer (extensionID → Layer).
    private var defaults: [String: Layer] = [:]
    /// Per-extension, per-tab override layer (extensionID → tabId → Layer).
    private var perTab: [String: [Int: Layer]] = [:]
    /// Cache of each extension's manifest-declared action (title/popup/icon), so the resolved state
    /// falls back to what the manifest shipped before the extension ever calls a setter.
    private var manifestAction: [String: WebExtensionManifest.Action] = [:]
    /// Cache of each extension's top-level manifest `icons`. Chrome uses these for the toolbar action
    /// when `action.default_icon` is absent, which is common — without this fallback such extensions
    /// render the generic puzzle glyph instead of their real icon.
    private var manifestIcons: [String: [String: String]] = [:]

    private let userDefaults: UserDefaults
    private static let persistKey = "brownbear.webext.actionDefaults.v1"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadDefaults()
    }

    // MARK: - Manifest seeding

    /// Record an extension's manifest-declared action so resolved state has a sensible base. Called
    /// when the browser builds the menu; cheap and idempotent. `fallbackIcons` is the manifest's
    /// top-level `icons`, used for the action icon when the action declares none (Chrome behaviour).
    func registerManifestAction(extensionID: String,
                                action: WebExtensionManifest.Action?,
                                fallbackIcons: [String: String] = [:]) {
        if let action {
            manifestAction[extensionID] = action
        } else {
            manifestAction.removeValue(forKey: extensionID)
        }
        if fallbackIcons.isEmpty {
            manifestIcons.removeValue(forKey: extensionID)
        } else {
            manifestIcons[extensionID] = fallbackIcons
        }
    }

    // MARK: - Reads

    /// The fully resolved action state for an extension in a given tab (`nil` tab = defaults only).
    func resolved(extensionID: String, tabId: Int?) -> Resolved {
        let manifest = manifestAction[extensionID]
        let base = defaults[extensionID]
        let tab = tabId.flatMap { perTab[extensionID]?[$0] }

        func pick<T>(_ keyPath: (Layer) -> T?) -> T? {
            if let tab, let value = keyPath(tab) { return value }
            if let base, let value = keyPath(base) { return value }
            return nil
        }

        let badgeText = pick(\.badgeText) ?? ""
        let badgeColor = pick(\.badgeColor) ?? "#666666"
        let title = pick(\.title) ?? manifest?.defaultTitle ?? ""
        // popup: an explicit "" means "no popup, fire onClicked"; nil falls through to the manifest.
        let popup: String?
        if let override = pick(\.popup) {
            popup = override.isEmpty ? nil : override
        } else {
            popup = manifest?.defaultPopup
        }
        let iconPath = pick(\.iconPath) ?? bestManifestIcon(manifest, fallbackIcons: manifestIcons[extensionID])
        let enabled = pick(\.enabled) ?? true

        return Resolved(badgeText: badgeText, badgeColor: badgeColor, title: title,
                        popup: popup, iconPath: iconPath, enabled: enabled)
    }

    /// chrome.action.getBadgeText / getTitle / getBadgeBackgroundColor / getPopup readback.
    func badgeText(extensionID: String, tabId: Int?) -> String {
        resolved(extensionID: extensionID, tabId: tabId).badgeText
    }
    func title(extensionID: String, tabId: Int?) -> String {
        resolved(extensionID: extensionID, tabId: tabId).title
    }
    func badgeColor(extensionID: String, tabId: Int?) -> String {
        resolved(extensionID: extensionID, tabId: tabId).badgeColor
    }
    /// chrome.action.getBadgeBackgroundColor resolves to a ColorArray ([r,g,b,a], 0–255). Convert our
    /// stored "#rgb"/"#rrggbb"/"#rrggbbaa" to that shape; opaque grey if it can't be parsed.
    func badgeColorBytes(extensionID: String, tabId: Int?) -> [Int] {
        Self.colorBytes(badgeColor(extensionID: extensionID, tabId: tabId))
    }
    static func colorBytes(_ css: String) -> [Int] {
        var hex = css.hasPrefix("#") ? String(css.dropFirst()) : css
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }      // #rgb → #rrggbb
        if hex.count == 6 { hex += "ff" }
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return [102, 102, 102, 255] }
        return [Int((value >> 24) & 0xff), Int((value >> 16) & 0xff),
                Int((value >> 8) & 0xff), Int(value & 0xff)]
    }
    /// The resolved popup path for a tab (empty string = no popup → onClicked). Used by the menu to
    /// decide whether tapping the entry opens a popup or fires onClicked.
    func popupPath(extensionID: String, tabId: Int?) -> String? {
        resolved(extensionID: extensionID, tabId: tabId).popup
    }
    func isEnabled(extensionID: String, tabId: Int?) -> Bool {
        resolved(extensionID: extensionID, tabId: tabId).enabled
    }

    // MARK: - Writes
    //
    // Each setter mutates either the per-tab layer (when `tabId` is given) or the default layer, then
    // posts the change. Passing the property's "clear" value (Chrome: "" for badge text, null/"" for
    // a color/title/popup) resets that layer's value to nil so the layer below shows through again.

    func setBadgeText(extensionID: String, tabId: Int?, text: String?) {
        mutate(extensionID: extensionID, tabId: tabId) { $0.badgeText = (text?.isEmpty == false) ? text : nil }
    }

    func setBadgeColor(extensionID: String, tabId: Int?, color: String?) {
        mutate(extensionID: extensionID, tabId: tabId) { $0.badgeColor = (color?.isEmpty == false) ? color : nil }
    }

    func setTitle(extensionID: String, tabId: Int?, title: String?) {
        mutate(extensionID: extensionID, tabId: tabId) { $0.title = title }
    }

    /// setPopup: Chrome treats an empty string as "no popup" (onClicked fires). We store the literal
    /// string (including "") so `resolved` can distinguish "" (disable) from nil (use manifest).
    func setPopup(extensionID: String, tabId: Int?, popup: String?) {
        mutate(extensionID: extensionID, tabId: tabId) { $0.popup = popup }
    }

    /// setIcon: we can't render arbitrary ImageData on iOS, but we DO honor a `path` (single or the
    /// best entry of a size→path map), so the menu can load the chosen icon from the extension bundle.
    func setIcon(extensionID: String, tabId: Int?, path: String?) {
        mutate(extensionID: extensionID, tabId: tabId) { $0.iconPath = (path?.isEmpty == false) ? path : nil }
    }

    /// enable()/disable(). A tab id scopes it to that tab; otherwise it's the default.
    func setEnabled(extensionID: String, tabId: Int?, _ enabled: Bool) {
        mutate(extensionID: extensionID, tabId: tabId) { $0.enabled = enabled }
    }

    /// Drop a closed tab's overrides for every extension so a reused chrome tab id can't inherit a
    /// stale badge. Called from the browser when a tab closes.
    func forgetTab(_ tabId: Int) {
        var changed: [String] = []
        for (extID, var tabs) in perTab where tabs[tabId] != nil {
            tabs.removeValue(forKey: tabId)
            perTab[extID] = tabs.isEmpty ? nil : tabs
            changed.append(extID)
        }
        for extID in changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil,
                                            userInfo: ["extensionID": extID])
        }
    }

    /// Drop all state for an uninstalled/disabled extension.
    func forgetExtension(_ extensionID: String) {
        let had = defaults[extensionID] != nil || perTab[extensionID] != nil
        defaults.removeValue(forKey: extensionID)
        perTab.removeValue(forKey: extensionID)
        manifestAction.removeValue(forKey: extensionID)
        manifestIcons.removeValue(forKey: extensionID)
        if had {
            persistDefaults()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil,
                                            userInfo: ["extensionID": extensionID])
        }
    }

    // MARK: - Internals

    private func mutate(extensionID: String, tabId: Int?, _ body: (inout Layer) -> Void) {
        if let tabId {
            var tabs = perTab[extensionID] ?? [:]
            var layer = tabs[tabId] ?? Layer()
            body(&layer)
            if layer.isEmpty { tabs.removeValue(forKey: tabId) } else { tabs[tabId] = layer }
            perTab[extensionID] = tabs.isEmpty ? nil : tabs
        } else {
            var layer = defaults[extensionID] ?? Layer()
            body(&layer)
            if layer.isEmpty { defaults.removeValue(forKey: extensionID) } else { defaults[extensionID] = layer }
            persistDefaults()
        }
        var userInfo: [String: Any] = ["extensionID": extensionID]
        if let tabId { userInfo["tabId"] = tabId }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: userInfo)
    }

    /// The action's declared icon, or — when it declares none — the manifest's top-level `icons`
    /// (Chrome falls back to these for the toolbar action).
    private func bestManifestIcon(_ action: WebExtensionManifest.Action?,
                                  fallbackIcons: [String: String]?) -> String? {
        if let icons = action?.defaultIcon, let best = Self.bestIcon(icons) { return best }
        if let fallbackIcons { return Self.bestIcon(fallbackIcons) }
        return nil
    }

    /// Resolve a chrome.action.setIcon `path` argument (a String, or a size→path map) to one path,
    /// preferring a sane toolbar size. `nil` for anything else (e.g. ImageData, unbridgeable on iOS).
    static func iconPath(from value: Any?) -> String? {
        if let single = value as? String { return single.isEmpty ? nil : single }
        if let map = value as? [String: String] { return bestIcon(map) }
        return nil
    }

    /// Pick the best entry of a size→path map: a sane toolbar size, then the largest, then any. Empty
    /// path values are ignored (a `"48": ""` entry would otherwise be "chosen" and then fail to load,
    /// dropping the row to the generic glyph).
    private static func bestIcon(_ rawIcons: [String: String]) -> String? {
        let icons = rawIcons.filter { !$0.value.isEmpty }
        guard !icons.isEmpty else { return nil }
        for size in ["32", "24", "19", "16", "48", "128"] {
            if let path = icons[size] { return path }
        }
        let largest = icons.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
        return largest?.value
    }

    // MARK: - Persistence (default layer only; per-tab is session-scoped)

    private func loadDefaults() {
        guard let raw = userDefaults.data(forKey: Self.persistKey),
              let decoded = try? JSONDecoder().decode([String: LayerCodable].self, from: raw) else { return }
        defaults = decoded.mapValues(\.layer)
    }

    private func persistDefaults() {
        let codable = defaults.mapValues(LayerCodable.init)
        if let data = try? JSONEncoder().encode(codable) {
            userDefaults.set(data, forKey: Self.persistKey)
        }
    }
}

private extension WebExtensionActionState.Layer {
    var isEmpty: Bool {
        badgeText == nil && badgeColor == nil && title == nil && popup == nil
            && iconPath == nil && enabled == nil
    }
}

/// Codable mirror of the (private) Layer so default-layer state survives a relaunch.
private struct LayerCodable: Codable {
    var badgeText: String?
    var badgeColor: String?
    var title: String?
    var popup: String?
    var iconPath: String?
    var enabled: Bool?

    init(_ layer: WebExtensionActionState.Layer) {
        badgeText = layer.badgeText
        badgeColor = layer.badgeColor
        title = layer.title
        popup = layer.popup
        iconPath = layer.iconPath
        enabled = layer.enabled
    }

    var layer: WebExtensionActionState.Layer {
        var l = WebExtensionActionState.Layer()
        l.badgeText = badgeText
        l.badgeColor = badgeColor
        l.title = title
        l.popup = popup
        l.iconPath = iconPath
        l.enabled = enabled
        return l
    }
}
