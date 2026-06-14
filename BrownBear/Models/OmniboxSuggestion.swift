//
//  OmniboxSuggestion.swift
//  BrownBear
//
//  The omnibox autocomplete dropdown's data: one row per suggestion, plus the pure engine that
//  composes the list from the typed text and matching history. Chrome-style ordering — the "what you
//  typed" default action is the top row (so it matches what Enter does), followed by visited pages.
//  No UIKit; fully unit-testable.
//

import Foundation

/// One suggestion row shown beneath the omnibox while editing.
struct OmniboxSuggestion: Equatable {

    enum Kind: Equatable {
        case search   // run a web search for the typed text
        case url      // navigate directly to a typed/known address
        case history  // a previously visited page matching the text
    }

    let kind: Kind
    /// Primary line (the query for search, the page title for history, the address for a URL).
    let title: String
    /// Secondary line (host, "Search the web", etc.). nil hides the second line.
    let subtitle: String?
    /// The URL to load when the row is chosen.
    let url: URL

    /// SF Symbol shown at the leading edge of the row.
    var iconName: String {
        switch kind {
        case .search: return "magnifyingglass"
        case .url: return "globe"
        case .history: return "clock"
        }
    }
}

/// Composes the ordered suggestion list. Pure logic: the caller fetches the history matches (the
/// store does the frecency ranking) and hands them in alongside the raw query.
enum OmniboxSuggestionEngine {

    /// - Parameters:
    ///   - rawQuery: exactly what the user has typed.
    ///   - historyMatches: history entries already matched + ranked by `HistoryStore.search`.
    ///   - searchTemplate: the active search engine template (for the search/url default row).
    /// - Returns: the default "typed text" action first, then de-duplicated history matches. Empty
    ///   for blank input (the caller shows top sites instead).
    static func compose(rawQuery: String,
                        historyMatches: [HistoryEntry],
                        searchTemplate: String) -> [OmniboxSuggestion] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        // Typing a leading bang ("!", "!y") → list the matching quick-search engines instead of the usual
        // rows, so the shortcuts are discoverable. Choosing one opens that engine's home.
        if query.hasPrefix("!"), !query.contains(" ") {
            let bangRows = SearchBangRegistry.matchingPrefix(String(query.dropFirst()))
                .compactMap { bang -> OmniboxSuggestion? in
                    guard let home = URL(string: bang.home) else { return nil }
                    return OmniboxSuggestion(kind: .search, title: "!\(bang.key)", subtitle: bang.name, url: home)
                }
            if !bangRows.isEmpty { return bangRows }
        }

        var suggestions: [OmniboxSuggestion] = []

        // Default action — mirrors what pressing Enter will do, so the highlighted top row is honest.
        let classifier = OmniboxInputClassifier(searchTemplate: searchTemplate)
        if let destination = try? classifier.destination(for: query) {
            switch destination {
            case .url(let url):
                suggestions.append(OmniboxSuggestion(kind: .url, title: query,
                                                     subtitle: url.host, url: url))
            case .search(let url):
                // Name the engine when a bang routes the search ("Search YouTube"), else the generic label.
                let label = SearchBangRegistry.match(in: query).map { "Search \($0.bang.name)" } ?? "Search the web"
                suggestions.append(OmniboxSuggestion(kind: .search, title: query,
                                                     subtitle: label, url: url))
            }
        }

        // Visited pages, skipping any duplicate of the default URL row.
        let defaultURL = suggestions.first?.url
        for entry in historyMatches where entry.url != defaultURL {
            suggestions.append(OmniboxSuggestion(kind: .history,
                                                 title: entry.displayTitle,
                                                 subtitle: entry.displayHost,
                                                 url: entry.url))
        }
        return suggestions
    }

    /// Map top-site history entries to suggestions for the empty-query state (shown the moment the
    /// omnibox gains focus, before the user types).
    static func topSites(_ entries: [HistoryEntry]) -> [OmniboxSuggestion] {
        entries.map { OmniboxSuggestion(kind: .history, title: $0.displayTitle,
                                        subtitle: $0.displayHost, url: $0.url) }
    }
}
