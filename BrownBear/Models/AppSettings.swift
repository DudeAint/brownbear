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

/// What happens when a `.user.js` is opened and one or more installed userscript-manager extensions
/// (ScriptCat, Violentmonkey, Tampermonkey, …) claim it. The user keeps the power: BrownBear's own
/// installer and any extension are both available.
enum UserScriptInstallPolicy: String, CaseIterable, Identifiable {
    /// Show the install sheet with a target for BrownBear AND each manager — the user picks (default).
    case ask
    /// Always install with BrownBear's built-in engine; never hand off to an extension.
    case brownBear
    /// Always hand off to a userscript-manager extension (route directly if there's one, pick if several);
    /// fall back to BrownBear only when no manager claims the script.
    case alwaysExtension

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .brownBear: return "Always BrownBear"
        case .alwaysExtension: return "Always a userscript extension"
        }
    }

    /// What the navigation delegate should do for a `.user.js` given this policy and how many installed
    /// managers claim the URL. Pure (table-tested) so the routing code stays a thin switch.
    enum Decision: Equatable {
        case nativeCard                  // BrownBear's install sheet, no manager targets
        case picker(showNativeInstall: Bool)   // the sheet with manager targets (+ optionally BrownBear)
        case routeToSingleManager        // exactly one manager and the policy says always-extension
    }

    func decision(managerCount: Int) -> Decision {
        switch self {
        case .brownBear:
            return .nativeCard
        case .ask:
            return managerCount == 0 ? .nativeCard : .picker(showNativeInstall: true)
        case .alwaysExtension:
            if managerCount == 0 { return .nativeCard }
            return managerCount == 1 ? .routeToSingleManager : .picker(showNativeInstall: false)
        }
    }
}

/// Which JS world an installed userscript-manager extension's userscripts run in. Managers (ScriptCat,
/// Tampermonkey) default a script to the page's MAIN world unless it declares `@inject-into content`. In
/// the MAIN world a userscript shares the page's globals — so a page that breaks its OWN globals (a
/// blocked analytics agent poisoning `window.addEventListener`, say) takes the userscript down with it.
/// The isolated "user script" world is a separate JS realm that shares only the DOM: immune to that, and
/// where the `GM_*` APIs live. Most userscripts work there; only one that must read/override the page's
/// own JS needs MAIN. (Same axis Violentmonkey gets right by sandboxing GM scripts by default.)
enum UserScriptWorld: String, CaseIterable, Identifiable {
    /// Force every manager userscript into the isolated user-script world (immune to page breakage). Default.
    case userScript
    /// Force every manager userscript into the page's real MAIN world (raw page access; no `GM_*` there).
    case main
    /// Honor the manager's per-script choice (`@inject-into` / `@grant`), exactly like Chrome.
    case managerChoice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userScript: return "User Script World (isolated)"
        case .main: return "Page (Main) World"
        case .managerChoice: return "Manager's choice"
        }
    }

    /// Map a manager-registered world ("MAIN" / "USER_SCRIPT" / "ISOLATED" / "") to the world BrownBear
    /// should actually run the script in, per this setting. Pure — unit-tested.
    func effectiveWorld(registered: String) -> String {
        switch self {
        case .userScript: return registered.uppercased() == "MAIN" ? "USER_SCRIPT" : registered
        case .main: return "MAIN"
        case .managerChoice: return registered
        }
    }
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
        static let userScriptInstallPolicy = "bbUserScriptInstallPolicy"
        static let userScriptWorld = "bbUserScriptWorld"
    }

    /// How a `.user.js` open is routed when userscript-manager extensions are installed. Default `.ask`
    /// (the Settings picker uses @AppStorage on the same key).
    static var userScriptInstallPolicy: UserScriptInstallPolicy {
        get { UserScriptInstallPolicy(rawValue: UserDefaults.standard.string(forKey: Key.userScriptInstallPolicy) ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.userScriptInstallPolicy) }
    }

    /// Which world a userscript-manager extension's userscripts run in. Default `.userScript` (isolated),
    /// so a userscript is immune to a page that breaks its own globals; the Settings picker uses
    /// @AppStorage on the same key. Read by the content-script router when it hands a manager's scripts
    /// to the page.
    static var userScriptWorld: UserScriptWorld {
        get { UserScriptWorld(rawValue: UserDefaults.standard.string(forKey: Key.userScriptWorld) ?? "") ?? .userScript }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.userScriptWorld) }
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
