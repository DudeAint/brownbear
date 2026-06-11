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

/// Which COLOR FAMILY the design tokens resolve to. `clean` is the default white/graphite look (it
/// still has light + dark variants); `og` is the original warm "BrownBear" amber/brown look (also
/// light + dark). Orthogonal to the OS light/dark axis — `BrownBearTheme` picks a hex by (family ×
/// light-or-dark). Kept Foundation-only here so any layer can read it; the UIKit mapping lives in
/// `BrownBearTheme`/`ThemeController`.
enum ThemeFamily {
    case clean
    case og
}

/// The user's chosen appearance. The clean Light/Dark family is the default and follows the OS; the
/// original warm look is preserved as an opt-in "OG BrownBear" theme (which also follows the OS
/// light/dark). The Settings picker uses `@AppStorage` on `Key.theme`; changing it posts
/// `.brownBearThemeChanged` so the open browser re-themes immediately.
enum AppTheme: String, CaseIterable, Identifiable {
    /// Clean family, follows the OS light/dark. The default.
    case system
    /// Clean family, forced light.
    case light
    /// Clean family, forced dark.
    case dark
    /// The original warm look (amber/brown), following the OS light/dark.
    case ogBrown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .ogBrown: return "OG BrownBear"
        }
    }

    /// The color family this theme resolves tokens from.
    var family: ThemeFamily { self == .ogBrown ? .og : .clean }
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
        static let keepVideosInline = "bbKeepVideosInline"
        static let theme = "bbTheme"
    }

    /// The app's appearance. Default `.system` (clean Light/Dark following the OS); the Settings picker
    /// uses @AppStorage on the same key. Changing it posts `.brownBearThemeChanged` (from the Settings
    /// screen / ThemeController) so the open browser re-themes without relaunch.
    static var theme: AppTheme {
        get { AppTheme(rawValue: UserDefaults.standard.string(forKey: Key.theme) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.theme) }
    }

    /// Keep <video> playing inline by neutralizing scripted/auto fullscreen (the Focus/Player-style
    /// "player" behavior — handy for automation that needs the page visible while a video plays). Default
    /// ON; the Settings toggle uses @AppStorage on the same key, so `object(forKey:) == nil` means "unset"
    /// → treat as true. Read at injection setup; takes effect on the next app launch (the page-world shim
    /// is installed on the shared content controller at boot).
    static var keepVideosInline: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.keepVideosInline) == nil
                ? true : UserDefaults.standard.bool(forKey: Key.keepVideosInline)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.keepVideosInline) }
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

    /// Posted when the appearance (`AppSettings.theme`) changes, so the open browser re-applies the
    /// window's interface style and re-themes its UIKit chrome (whose family-driven colors don't change
    /// on a pure light/dark trait cycle). SwiftUI surfaces observe `ThemeStore` instead.
    static let brownBearThemeChanged = Notification.Name("brownBearThemeChanged")

    /// Posted (with userInfo["url"] = URL) when a surface wants the browser to open a URL in a new tab —
    /// e.g. the dashboard's "Browse the stores" rows. The browser dismisses any presented sheet and loads
    /// it, so the dashboard doesn't need a reference to the browser controller.
    static let brownBearOpenURL = Notification.Name("brownBearOpenURL")
}
