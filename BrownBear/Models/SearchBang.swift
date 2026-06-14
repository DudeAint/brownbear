//
//  SearchBang.swift
//  BrownBear
//
//  Quick-search shortcuts ("bangs"), the DuckDuckGo/Kagi power-browser staple: typing "!yt funny cats"
//  searches YouTube, "swift docs !gh" searches GitHub. The bang token can sit anywhere in the omnibox
//  text; the rest (with the token removed) is the query. A bare "!yt" opens the engine's home. An
//  UNKNOWN bang (e.g. "!zzz foo") is left alone — it falls through to a normal search, exactly like DDG.
//
//  Pure value types + a curated default set; all resolution is fully unit-tested via OmniboxInputClassifier
//  and OmniboxSuggestionEngine. No UIKit.
//

import Foundation

/// One quick-search shortcut. `key` is the word typed after "!" (e.g. "yt"); `%@` in `searchTemplate`
/// is replaced with the percent-encoded query; `home` is where a bare "!key" (no query) navigates.
struct SearchBang: Equatable {
    let key: String
    let name: String
    let searchTemplate: String
    let home: String

    /// The URL a bang resolves to for `query` — the engine's home when the query is empty, otherwise the
    /// search template filled with the percent-encoded query. Nil only if the resulting string isn't a URL.
    func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return URL(string: home) }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .bangQueryAllowed) ?? trimmed
        return URL(string: searchTemplate.replacingOccurrences(of: "%@", with: encoded))
    }
}

/// The built-in bang set + lookup/match helpers. Shared by the classifier (resolution) and the suggestion
/// engine (the "Search <engine>" label + the "type !" autocomplete), so the behaviour can't drift apart.
enum SearchBangRegistry {

    /// Curated, high-traffic destinations a power user reaches for. Order is the autocomplete order.
    static let defaults: [SearchBang] = [
        SearchBang(key: "g", name: "Google",
                   searchTemplate: "https://www.google.com/search?q=%@", home: "https://www.google.com"),
        SearchBang(key: "ddg", name: "DuckDuckGo",
                   searchTemplate: "https://duckduckgo.com/?q=%@", home: "https://duckduckgo.com"),
        SearchBang(key: "b", name: "Bing",
                   searchTemplate: "https://www.bing.com/search?q=%@", home: "https://www.bing.com"),
        SearchBang(key: "yt", name: "YouTube",
                   searchTemplate: "https://www.youtube.com/results?search_query=%@", home: "https://www.youtube.com"),
        SearchBang(key: "w", name: "Wikipedia",
                   searchTemplate: "https://en.wikipedia.org/w/index.php?search=%@", home: "https://en.wikipedia.org"),
        SearchBang(key: "gh", name: "GitHub",
                   searchTemplate: "https://github.com/search?q=%@", home: "https://github.com"),
        SearchBang(key: "so", name: "Stack Overflow",
                   searchTemplate: "https://stackoverflow.com/search?q=%@", home: "https://stackoverflow.com"),
        SearchBang(key: "npm", name: "npm",
                   searchTemplate: "https://www.npmjs.com/search?q=%@", home: "https://www.npmjs.com"),
        SearchBang(key: "mdn", name: "MDN",
                   searchTemplate: "https://developer.mozilla.org/en-US/search?q=%@", home: "https://developer.mozilla.org"),
        SearchBang(key: "a", name: "Amazon",
                   searchTemplate: "https://www.amazon.com/s?k=%@", home: "https://www.amazon.com"),
        SearchBang(key: "r", name: "Reddit",
                   searchTemplate: "https://www.reddit.com/search/?q=%@", home: "https://www.reddit.com"),
        SearchBang(key: "x", name: "X",
                   searchTemplate: "https://x.com/search?q=%@", home: "https://x.com"),
        SearchBang(key: "maps", name: "Google Maps",
                   searchTemplate: "https://www.google.com/maps/search/%@", home: "https://www.google.com/maps"),
        SearchBang(key: "img", name: "Google Images",
                   searchTemplate: "https://www.google.com/search?tbm=isch&q=%@", home: "https://images.google.com"),
        SearchBang(key: "hn", name: "Hacker News",
                   searchTemplate: "https://hn.algolia.com/?q=%@", home: "https://news.ycombinator.com"),
        SearchBang(key: "wa", name: "Wolfram Alpha",
                   searchTemplate: "https://www.wolframalpha.com/input?i=%@", home: "https://www.wolframalpha.com"),
        SearchBang(key: "imdb", name: "IMDb",
                   searchTemplate: "https://www.imdb.com/find/?q=%@", home: "https://www.imdb.com"),
        SearchBang(key: "tr", name: "Google Translate",
                   searchTemplate: "https://translate.google.com/?text=%@", home: "https://translate.google.com")
    ]

    /// Lowercased trigger word → bang.
    static let byKey: [String: SearchBang] = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key, $0) })

    /// If `text` contains a known bang token (a space-delimited "!key" whose key is in the registry),
    /// returns that bang and the remaining text as the query (the bang token removed). The FIRST known
    /// bang wins; an unknown "!foo" is ignored (left in the query). Nil when there's no known bang.
    static func match(in text: String) -> (bang: SearchBang, query: String)? {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for (index, token) in tokens.enumerated() where token.hasPrefix("!") && token.count > 1 {
            let key = String(token.dropFirst()).lowercased()
            guard let bang = byKey[key] else { continue }
            var rest = tokens
            rest.remove(at: index)
            return (bang, rest.joined(separator: " "))
        }
        return nil
    }

    /// Bangs whose key starts with `prefix` (the text after a leading "!"), shortest key first — for the
    /// "you typed !" autocomplete. An empty prefix returns the whole set.
    static func matchingPrefix(_ prefix: String) -> [SearchBang] {
        let needle = prefix.lowercased()
        return defaults
            .filter { needle.isEmpty || $0.key.hasPrefix(needle) }
            .sorted { ($0.key.count, $0.key) < ($1.key.count, $1.key) }
    }
}

private extension CharacterSet {
    /// Query-value characters for a bang URL (matches OmniboxInputClassifier's encoding so a bang search
    /// and a normal search encode identically).
    static let bangQueryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
