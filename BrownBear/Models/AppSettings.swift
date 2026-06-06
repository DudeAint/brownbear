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

/// Namespaced UserDefaults-backed app preferences. The SwiftUI Settings screen uses `@AppStorage`
/// on the same keys, so reads here and edits there stay in sync.
enum AppSettings {

    enum Key {
        static let searchEngine = "bbSearchEngine"
    }

    static var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: UserDefaults.standard.string(forKey: Key.searchEngine) ?? "") ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.searchEngine) }
    }
}
