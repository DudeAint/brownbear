//
//  UserScriptInstallRouter.swift
//  BrownBear
//
//  Routes a `.user.js` main-frame navigation to an INSTALLED userscript-manager extension that claims it,
//  the way Chrome does — instead of BrownBear's own native install card.
//
//  In Chrome, a manager like ScriptCat registers a declarativeNetRequest `redirect` rule that rewrites a
//  `*.user.js` main-frame request to its own install page (`install.html?url=<original>`), and the install
//  page self-fetches the script. WebKit can't perform a DNR redirect of a main-frame request (our content
//  rule list compiler skips `redirect`), so we evaluate the SAME stored rule here, in the navigation
//  delegate's `.user.js` decision point, and open the computed extension page ourselves. Reusing the
//  extension's own rule means no per-manager special-casing: any manager whose redirect target is
//  self-sufficient from the URL it carries (ScriptCat's `?url=`) just works.
//
//  This type is PURE (no actor state, no I/O) so it is fully table-testable: it maps (URL, extension id,
//  the extension's merged DNR rules) → the redirect a `redirect` rule would produce, or nil.
//

import Foundation

enum UserScriptInstallRouter {

    /// The extension + target a matching DNR `redirect` rule would send a request to.
    struct Redirect: Equatable {
        let extensionID: String
        let target: URL
    }

    /// The redirect a `redirect`-action DNR rule in `rules` would produce for `url` (treated as a
    /// main-frame GET, which is what a `.user.js` navigation is), or nil if none matches. The first
    /// matching rule wins (callers pass rules in Chrome precedence order: session/dynamic over static).
    static func redirect(for url: URL, extensionID: String, rules: [[String: Any]]) -> Redirect? {
        let urlString = url.absoluteString
        let host = url.host?.lowercased() ?? ""
        for rule in rules {
            guard let action = rule["action"] as? [String: Any],
                  (action["type"] as? String) == "redirect",
                  let redirect = action["redirect"] as? [String: Any],
                  let condition = rule["condition"] as? [String: Any] else { continue }

            // Resource type: a main-frame navigation. A rule that lists resourceTypes must include
            // "main_frame"; an excludedResourceTypes that lists it disqualifies the rule.
            if let types = condition["resourceTypes"] as? [String], !types.contains("main_frame") { continue }
            if let excluded = condition["excludedResourceTypes"] as? [String], excluded.contains("main_frame") { continue }

            // Method: the navigation is a GET. A rule restricting requestMethods must allow it.
            if let methods = condition["requestMethods"] as? [String],
               !methods.contains(where: { $0.lowercased() == "get" }) { continue }

            // Domain gates (host or any subdomain of a listed domain).
            if let requestDomains = condition["requestDomains"] as? [String], !requestDomains.isEmpty,
               !requestDomains.contains(where: { hostMatches(host, domain: $0) }) { continue }
            if let excludedDomains = condition["excludedRequestDomains"] as? [String],
               excludedDomains.contains(where: { hostMatches(host, domain: $0) }) { continue }

            let caseSensitive = (condition["isUrlFilterCaseSensitive"] as? Bool) ?? false

            if let regexFilter = condition["regexFilter"] as? String, !regexFilter.isEmpty {
                let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                guard let re = try? NSRegularExpression(pattern: regexFilter, options: options) else { continue }
                let range = NSRange(urlString.startIndex..., in: urlString)
                guard let match = re.firstMatch(in: urlString, options: [], range: range) else { continue }
                if let target = computeTarget(redirect, extensionID: extensionID, match: match, source: urlString) {
                    return Redirect(extensionID: extensionID, target: target)
                }
            } else if let urlFilter = condition["urlFilter"] as? String, !urlFilter.isEmpty {
                guard urlFilterMatches(urlFilter, urlString, caseSensitive: caseSensitive) else { continue }
                if let target = computeTarget(redirect, extensionID: extensionID, match: nil, source: urlString) {
                    return Redirect(extensionID: extensionID, target: target)
                }
            } else {
                // No urlFilter/regexFilter → matches every URL (subject to the gates above).
                if let target = computeTarget(redirect, extensionID: extensionID, match: nil, source: urlString) {
                    return Redirect(extensionID: extensionID, target: target)
                }
            }
        }
        return nil
    }

    // MARK: - Redirect target

    /// Resolve a DNR `redirect` object to a concrete URL. Supports the three forms a userscript manager
    /// uses: `regexSubstitution` (with `\0…\9` back-references into the regexFilter match — ScriptCat's
    /// `…/install.html?url=\1`), `extensionPath`, and an absolute `url`. `transform` is not supported.
    private static func computeTarget(_ redirect: [String: Any], extensionID: String,
                                      match: NSTextCheckingResult?, source: String) -> URL? {
        if let substitution = redirect["regexSubstitution"] as? String, let match {
            let resolved = applyRegexSubstitution(substitution, match: match, source: source)
            return URL(string: resolved)
        }
        if let extensionPath = redirect["extensionPath"] as? String {
            let path = extensionPath.hasPrefix("/") ? extensionPath : "/" + extensionPath
            return URL(string: "\(WebExtensionSchemeHandler.scheme)://\(extensionID)\(path)")
        }
        if let absolute = redirect["url"] as? String {
            return URL(string: absolute)
        }
        return nil
    }

    /// Apply Chrome's DNR `regexSubstitution` escaping: `\0`…`\9` insert the corresponding capture group
    /// of `match`, `\\` is a literal backslash. The script URL is inserted verbatim (ScriptCat's install
    /// page reads `location.search` and parses it with `new URL()`, so it is not percent-encoded).
    static func applyRegexSubstitution(_ template: String, match: NSTextCheckingResult, source: String) -> String {
        var out = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "\\" {
                    out.append("\\")
                    i += 2
                    continue
                }
                if let group = next.wholeNumberValue, (0...9).contains(group) {
                    if group < match.numberOfRanges {
                        let nsRange = match.range(at: group)
                        if nsRange.location != NSNotFound, let r = Range(nsRange, in: source) {
                            out += String(source[r])
                        }
                    }
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    // MARK: - Matching helpers

    /// A DNR domain matches the host itself or any subdomain of it.
    private static func hostMatches(_ host: String, domain: String) -> Bool {
        let d = domain.lowercased()
        return host == d || host.hasSuffix("." + d)
    }

    /// Match a DNR `urlFilter` (the substring/anchor mini-syntax) against a URL. `*` is a wildcard, a
    /// leading/trailing `|` anchors start/end, a leading `||` anchors the host (subdomain boundary), and
    /// `^` is a separator (any char that is not a letter, digit, `_`, `-`, `.`, or `%`, or end-of-URL).
    /// We translate to a regex and match; an untranslatable filter simply fails to match (fail closed,
    /// so we fall back to BrownBear's native install card rather than mis-route).
    static func urlFilterMatches(_ filter: String, _ urlString: String, caseSensitive: Bool) -> Bool {
        guard let pattern = regexPattern(fromURLFilter: filter) else { return false }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(urlString.startIndex..., in: urlString)
        return re.firstMatch(in: urlString, options: [], range: range) != nil
    }

    private static func regexPattern(fromURLFilter filter: String) -> String? {
        var chars = Array(filter)
        var pattern = ""
        var index = 0

        if chars.first == "|" && chars.dropFirst().first == "|" {
            // `||` — anchor at the start of the host (after the scheme), allowing any subdomain.
            pattern += "^[a-z][a-z0-9+.-]*://([^/]*\\.)?"
            index = 2
        } else if chars.first == "|" {
            pattern += "^"
            index = 1
        }

        var anchorEnd = false
        if chars.last == "|" {
            anchorEnd = true
            chars.removeLast()
        }

        while index < chars.count {
            let c = chars[index]
            switch c {
            case "*":
                pattern += ".*"
            case "^":
                pattern += "[^a-zA-Z0-9_.%-]"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(c))
            }
            index += 1
        }

        if anchorEnd { pattern += "$" }
        return pattern
    }
}
