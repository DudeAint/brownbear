//
//  AppSettings.swift
//  BrownBear
//
//  App-wide preferences backed by UserDefaults. Kept tiny and dependency-free so any layer (the
//  omnibox classifier, the NTP, the dashboard) can read a setting synchronously.
//

import Foundation

/// The user's chosen web search engine. `template`/`formAction` drive the omnibox and the NTP search box.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, brave, ecosia, startpage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        }
    }

    /// Omnibox search template; `%@` is replaced with the percent-encoded query.
    var template: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%@"
        case .duckDuckGo: return "https://duckduckgo.com/?q=%@"
        case .bing: return "https://www.bing.com/search?q=%@"
        case .brave: return "https://search.brave.com/search?q=%@"
        case .ecosia: return "https://www.ecosia.org/search?q=%@"
        case .startpage: return "https://www.startpage.com/sp/search?query=%@"
        }
    }

    /// The `<form action>` base URL for the New Tab page search box.
    var formAction: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .bing: return "https://www.bing.com/search"
        case .brave: return "https://search.brave.com/search"
        case .ecosia: return "https://www.ecosia.org/search"
        case .startpage: return "https://www.startpage.com/sp/search"
        }
    }

    /// The GET query parameter name for the NTP search form.
    var formQueryParam: String { self == .startpage ? "query" : "q" }
}

/// Where the address bar (omnibox) lives — at the top (Chrome-style, default) or at the bottom above
/// the toolbar (Safari-style). In bottom mode the omnibox + toolbar collapse away together on scroll.
enum AddressBarPosition: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var title: String { self == .top ? "Top" : "Bottom" }
}

/// Namespaced UserDefaults-backed app preferences. The SwiftUI Settings screen uses `@AppStorage`
/// on the same keys, so reads here and edits there stay in sync.
enum AppSettings {

    enum Key {
        static let searchEngine = "bbSearchEngine"
        static let autoUpdateScripts = "bbAutoUpdateScripts"
        static let lastScriptUpdateCheck = "bbLastScriptUpdateCheck"
        static let hideBarsOnScroll = "bbHideBarsOnScroll"
        static let addressBarPosition = "bbAddressBarPosition"
    }

    /// Where the address bar sits. Default `.top`. Changing it posts `.brownBearChromeLayoutChanged`
    /// (from the Settings screen) so the open browser re-lays-out its chrome immediately.
    static var addressBarPosition: AddressBarPosition {
        get { AddressBarPosition(rawValue: UserDefaults.standard.string(forKey: Key.addressBarPosition) ?? "") ?? .top }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.addressBarPosition) }
    }

    /// Whether the browser chrome (the omnibox bar) slides away as you scroll the page down and returns
    /// when you scroll up — the Safari/Chrome immersive-reading behaviour. Default ON; the Settings
    /// toggle uses @AppStorage on the same key, so `object(forKey:) == nil` means "unset" → treat as true.
    static var hideBarsOnScroll: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.hideBarsOnScroll) == nil
                ? true : UserDefaults.standard.bool(forKey: Key.hideBarsOnScroll)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.hideBarsOnScroll) }
    }

    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: UserDefaults.standard.string(forKey: Key.searchEngine) ?? "") ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.searchEngine) }
    }

    /// Whether installed userscripts are checked for newer @versions automatically. Default ON; the
    /// Settings toggle uses @AppStorage on the same key, so `object(forKey:) == nil` means "unset" →
    /// treat as true.
    static var autoUpdateScripts: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.autoUpdateScripts) == nil
                ? true : UserDefaults.standard.bool(forKey: Key.autoUpdateScripts)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoUpdateScripts) }
    }

    /// When the automatic update check last ran, so we don't re-check on every dashboard open.
    static var lastScriptUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: Key.lastScriptUpdateCheck) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastScriptUpdateCheck) }
    }
}

extension Notification.Name {
    /// Posted when a chrome-layout preference (e.g. the address-bar position) changes, so the open
    /// browser controller re-applies its layout immediately instead of only on next launch.
    static let brownBearChromeLayoutChanged = Notification.Name("brownBearChromeLayoutChanged")
}
