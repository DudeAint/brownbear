//
//  OmniboxInputClassifier.swift
//  BrownBear
//
//  Turns raw omnibox text into a concrete destination, mirroring how Chrome's omnibox decides
//  between "navigate to a URL" and "search". Pure logic, no UIKit — fully unit-tested.
//

import Foundation

/// The resolved intent of what the user typed into the omnibox.
enum OmniboxDestination: Equatable {
    /// Navigate directly to this URL.
    case url(URL)
    /// Run a web search for this query.
    case search(URL)

    /// The URL to actually load, regardless of intent.
    var resolvedURL: URL {
        switch self {
        case .url(let url), .search(let url):
            return url
        }
    }
}

/// Classifies omnibox text into a `OmniboxDestination`.
struct OmniboxInputClassifier {

    /// Template for the search engine. `%@` is replaced with the percent-encoded query.
    let searchTemplate: String
    /// Whether quick-search bangs ("!yt cats") are honoured. Off makes the classifier ignore them so the
    /// text searches literally — used by tests, and a future Settings toggle could flip it.
    let bangsEnabled: Bool

    init(searchTemplate: String = "https://www.google.com/search?q=%@", bangsEnabled: Bool = true) {
        self.searchTemplate = searchTemplate
        self.bangsEnabled = bangsEnabled
    }

    /// A small set of schemes we will navigate to directly when the user types them.
    private static let navigableSchemes: Set<String> = ["http", "https", "file", "about", "data"]

    /// Resolve typed text into a destination.
    /// - Returns: a `.url` when the text looks like an address, otherwise a `.search`.
    /// - Throws: `BrownBearError.invalidOmniboxInput` if neither a URL nor a search can be built.
    func destination(for rawText: String) throws -> OmniboxDestination {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BrownBearError.invalidOmniboxInput(rawText) }

        // 0. Quick-search bang ("!yt funny cats", "swift docs !gh"). A known bang routes to that engine;
        // a bare "!yt" opens its home. Unknown bangs are left alone and handled as ordinary text below.
        if bangsEnabled, let (bang, query) = SearchBangRegistry.match(in: text), let url = bang.url(for: query) {
            return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .url(url) : .search(url)
        }

        // 1. Explicit scheme the user typed (https://…, about:blank, file://…).
        if let scheme = explicitScheme(in: text) {
            if Self.navigableSchemes.contains(scheme), let url = URL(string: text) {
                return .url(url)
            }
            // Unknown scheme (e.g. mailto:) — still navigate; the system may handle it.
            if let url = URL(string: text) { return .url(url) }
        }

        // 2. Looks like a bare host ("example.com", "localhost:3000", "192.168.0.1/path").
        if looksLikeHost(text), let url = URL(string: "https://\(text)") {
            return .url(url)
        }

        // 3. Otherwise it's a search.
        return .search(try searchURL(for: text))
    }

    // MARK: - Heuristics

    /// Returns the lowercased scheme if `text` begins with one, else nil.
    private func explicitScheme(in text: String) -> String? {
        guard let range = text.range(of: "://") else {
            // Handle scheme-only forms like "about:blank" / "mailto:x@y.com", but NOT a
            // host:port such as "localhost:3000" — if digits follow the colon it's a port.
            if let colon = text.firstIndex(of: ":") {
                let candidate = String(text[text.startIndex..<colon]).lowercased()
                let afterColon = text[text.index(after: colon)...]
                if let first = afterColon.first, first.isNumber { return nil }
                if !candidate.isEmpty, candidate.allSatisfy({ $0.isLetter }) {
                    return candidate
                }
            }
            return nil
        }
        return String(text[text.startIndex..<range.lowerBound]).lowercased()
    }

    /// Heuristic: does this read like a hostname rather than a search phrase?
    private func looksLikeHost(_ text: String) -> Bool {
        // A space means it's almost certainly a search.
        if text.contains(" ") { return false }

        // Strip any path/query/port to inspect just the host part.
        let host = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let hostNoPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(host)

        if hostNoPort.isEmpty { return false }
        if hostNoPort.lowercased() == "localhost" { return true }
        if isIPv4(hostNoPort) { return true }

        // Must contain a dot and a plausible TLD (letters, length >= 2) with no spaces.
        guard let lastDot = hostNoPort.lastIndex(of: ".") else { return false }
        let tld = hostNoPort[hostNoPort.index(after: lastDot)...]
        guard tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }

        // The label before the TLD must be non-empty and use host-legal characters
        // (letters, digits, hyphen, underscore, and the dots that separate labels).
        let labels = hostNoPort.split(separator: ".")
        guard labels.count >= 2 else { return false }
        let legal = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return hostNoPort.unicodeScalars.allSatisfy { legal.contains($0) }
    }

    private func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return true
        }
    }

    private func searchURL(for query: String) throws -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
            ?? query
        guard let url = URL(string: searchTemplate.replacingOccurrences(of: "%@", with: encoded)) else {
            throw BrownBearError.invalidOmniboxInput(query)
        }
        return url
    }
}

private extension CharacterSet {
    /// URL query value characters (a stricter set than `.urlQueryAllowed`, which permits `&=`).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
