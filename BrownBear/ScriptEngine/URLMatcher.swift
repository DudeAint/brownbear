//
//  URLMatcher.swift
//  BrownBear
//
//  Decides whether a userscript should run on a given URL. It implements the same semantics as
//  the established managers (quoid/userscripts' Functions.swift):
//    • @match / @exclude-match  → Chrome match-pattern grammar (scheme://host/path, http/https
//      only, `*` wildcards, `*.host` for subdomains, `<all_urls>`).
//    • @include / @exclude      → glob (with `*`) or `/regex/`, tested against the full URL.
//    • Exclusion always wins.
//  Regexes are compiled once at init. Pure logic — fully unit-tested.
//
//  Note: WebKit's RegExp engine gained lookbehind/lookahead only in iOS 16.4; our generated
//  patterns avoid both, and the app's deployment target is 16.4+ regardless.
//

import Foundation

struct URLMatcher {

    /// A compiled Chrome match pattern, split into the parts `match()` tests independently.
    private struct CompiledMatchPattern {
        let scheme: String              // "http:", "https:", or "*:"
        let hostRegex: NSRegularExpression
        let pathRegex: NSRegularExpression
    }

    private let includePatterns: [CompiledMatchPattern]      // from @match
    private let excludePatterns: [CompiledMatchPattern]      // from @exclude-match
    private let includeRegexes: [NSRegularExpression]        // from @include
    private let excludeRegexes: [NSRegularExpression]        // from @exclude
    private let matchesAllURLs: Bool                         // any @match was <all_urls>

    /// Parses a Chrome match pattern into (scheme, host, path). The host alternation accepts a
    /// dotted/wildcard hostname OR a bracketed IPv6 literal (e.g. `[::1]`, `[2001:db8::1]`).
    private static let matchPatternRegex = try? NSRegularExpression(
        pattern: #"^(http:|https:|\*:)//((?:\*\.)?(?:[a-z0-9-]+\.)+(?:[a-z0-9]+)|\*\.[a-z]+|\*|[a-z0-9]+|\[[0-9a-f:.]+\])(/[^\s]*)$"#,
        options: .caseInsensitive)

    init(metadata: ScriptMetadata) {
        self.init(matches: metadata.matches,
                  includes: metadata.includes,
                  excludes: metadata.excludes,
                  excludeMatches: metadata.excludeMatches)
    }

    init(matches: [String], includes: [String], excludes: [String], excludeMatches: [String]) {
        var includePatterns: [CompiledMatchPattern] = []
        var allURLs = false
        for pattern in matches {
            if pattern == "<all_urls>" { allURLs = true; continue }
            if let compiled = Self.compileMatchPattern(pattern) { includePatterns.append(compiled) }
        }
        self.includePatterns = includePatterns
        self.matchesAllURLs = allURLs
        self.excludePatterns = excludeMatches.compactMap(Self.compileMatchPattern)
        self.includeRegexes = includes.compactMap(Self.compileIncludeOrExclude)
        self.excludeRegexes = excludes.compactMap(Self.compileIncludeOrExclude)
    }

    // MARK: - Matching

    /// Whether a script with these directives should run on `urlString`. Exclusion wins.
    func matches(_ urlString: String) -> Bool {
        let fullRange = NSRange(urlString.startIndex..., in: urlString)

        // 1. Exclusions first — any hit means "do not run".
        for regex in excludeRegexes where regex.firstMatch(in: urlString, range: fullRange) != nil {
            return false
        }
        if !excludePatterns.isEmpty, let parts = Self.parse(urlString) {
            for pattern in excludePatterns where Self.matches(parts: parts, pattern: pattern) {
                return false
            }
        }

        // 2. Inclusions.
        if matchesAllURLs, let parts = Self.parse(urlString),
           parts.scheme == "http:" || parts.scheme == "https:" {
            return true
        }
        if !includePatterns.isEmpty, let parts = Self.parse(urlString) {
            for pattern in includePatterns where Self.matches(parts: parts, pattern: pattern) {
                return true
            }
        }
        for regex in includeRegexes where regex.firstMatch(in: urlString, range: fullRange) != nil {
            return true
        }
        return false
    }

    // MARK: - Match-pattern evaluation

    private struct URLParts { let scheme: String; let host: String; let path: String }

    private static func matches(parts: URLParts, pattern: CompiledMatchPattern) -> Bool {
        // Match patterns only apply to http/https.
        guard parts.scheme == "http:" || parts.scheme == "https:" else { return false }
        if pattern.scheme != "*:" && parts.scheme != pattern.scheme { return false }
        let hostRange = NSRange(parts.host.startIndex..., in: parts.host)
        let pathRange = NSRange(parts.path.startIndex..., in: parts.path)
        guard pattern.hostRegex.firstMatch(in: parts.host, range: hostRange) != nil,
              pattern.pathRegex.firstMatch(in: parts.path, range: pathRange) != nil else {
            return false
        }
        return true
    }

    // MARK: - Compilation

    private static func compileMatchPattern(_ pattern: String) -> CompiledMatchPattern? {
        guard let regex = matchPatternRegex else { return nil }
        let range = NSRange(pattern.startIndex..., in: pattern)
        guard let match = regex.firstMatch(in: pattern, range: range),
              let schemeRange = Range(match.range(at: 1), in: pattern),
              let hostRange = Range(match.range(at: 2), in: pattern),
              let pathRange = Range(match.range(at: 3), in: pattern) else {
            return nil
        }
        let scheme = String(pattern[schemeRange])
        let hostToken = String(pattern[hostRange])
        let pathToken = String(pattern[pathRange])

        // Host → anchored regex. An IPv6 literal ([::1]) is matched EXACTLY (its brackets/colons are
        // regex metacharacters, so escape the whole token — no dot/wildcard expansion). A hostname
        // escapes dots and expands the `*` / `*.` wildcards (mirrors the reference exactly).
        let hostPattern: String
        if hostToken.hasPrefix("[") && hostToken.hasSuffix("]") {
            hostPattern = "^" + NSRegularExpression.escapedPattern(for: hostToken) + "$"
        } else {
            var pattern = "^" + hostToken.replacingOccurrences(of: ".", with: "\\.") + "$"
            pattern = pattern.replacingOccurrences(of: "^*$", with: ".*")
            pattern = pattern.replacingOccurrences(of: "*\\.", with: "(.*\\.)?")
            hostPattern = pattern
        }

        guard let hostRegex = try? NSRegularExpression(pattern: hostPattern, options: .caseInsensitive),
              let pathRegex = try? NSRegularExpression(pattern: globToRegexPattern(pathToken),
                                                       options: .caseInsensitive) else {
            return nil
        }
        return CompiledMatchPattern(scheme: scheme, hostRegex: hostRegex, pathRegex: pathRegex)
    }

    /// Compile an @include / @exclude value: a `/regex/` literal or a glob.
    private static func compileIncludeOrExclude(_ pattern: String) -> NSRegularExpression? {
        if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let inner = String(pattern.dropFirst().dropLast())
            return try? NSRegularExpression(pattern: inner, options: .caseInsensitive)
        }
        return try? NSRegularExpression(pattern: globToRegexPattern(pattern), options: .caseInsensitive)
    }

    /// Convert a glob (with `*`) to an anchored regex pattern, escaping regex metacharacters
    /// exactly as the reference `stringToRegex` does.
    private static func globToRegexPattern(_ glob: String) -> String {
        let specials: Set<Character> = [".", "?", "^", "$", "+", "{", "}", "[", "]", "|", "(", ")", "/", "\\"]
        var out = "^"
        for ch in glob {
            if ch == "*" {
                out += ".*"
            } else if specials.contains(ch) {
                out.append("\\")
                out.append(ch)
            } else {
                out.append(ch)
            }
        }
        out += "$"
        return out
    }

    /// Split a URL into the scheme (with trailing colon), host, and path+query the matcher tests.
    private static func parse(_ urlString: String) -> URLParts? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme else { return nil }
        var host = components.host ?? ""
        // URLComponents strips the brackets off an IPv6 host (::1); restore them so the host matches a
        // bracketed match-pattern host ([::1]). A normal hostname/IPv4 never contains a colon.
        if host.contains(":") { host = "[\(host)]" }
        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?" + query
        }
        return URLParts(scheme: scheme.lowercased() + ":", host: host, path: path)
    }
}
