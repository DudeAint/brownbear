//
//  WebExtensionDNRRedirect.swift
//  BrownBear
//
//  declarativeNetRequest `redirect` rules for MAIN-FRAME navigations. WKContentRuleList can't express
//  `redirect` (DeclarativeNetRequest.translate .skip()s it), so the whole redirect-extension class
//  (old-reddit-redirect, LibRedirect, privacy-redirect, …) is otherwise dead. We instead match the
//  rule at navigation time (WKNavigationDelegate) and load the computed target.
//
//  This file is the PURE, fully unit-tested core: parse an extension's rules into main-frame redirect
//  rules, find the highest-priority match for a URL, and compute the redirect target. It is deliberately
//  CONSERVATIVE because a false match diverts NORMAL browsing — the worst possible failure:
//    • only rules that EXPLICITLY list `main_frame` in resourceTypes apply (Chrome's default omits
//      main_frame anyway; requiring it can only UNDER-match, which is safe);
//    • a rule carrying request/initiator-domain conditions is SKIPPED (we don't risk mis-evaluating a
//      condition we don't fully model — under-match, not over-match);
//    • a regexFilter that won't compile, or a urlFilter that yields no regex, drops the rule;
//    • the computed target must be an absolute http(s)/chrome-extension URL and DIFFERENT from the
//      source (the loop/no-op guard) or the match is rejected.
//  The urlFilter→regex translation is reused verbatim from DeclarativeNetRequest (the same logic that
//  backs the shipped, tested blocking path), so the matcher isn't a second hand-rolled glob.
//

import Foundation

enum WebExtensionDNRRedirect {

    /// A parsed main-frame redirect rule, ready to match at navigation time.
    struct Rule {
        let extensionID: String
        let priority: Int
        let urlRegex: NSRegularExpression
        let caseSensitive: Bool
        /// The raw regexFilter, kept only when the rule matched via regexFilter (needed for
        /// `regexSubstitution`, which references its capture groups). nil for a urlFilter rule.
        let regexFilter: String?
        /// The `action.redirect` object (url / extensionPath / regexSubstitution / transform).
        let redirect: [String: Any]
    }

    // MARK: - Parse

    /// Parse an extension's DNR rules into the main-frame redirect rules we can safely apply, in the
    /// order they should be tried (highest priority first; DNR breaks ties by rule id, lower id first).
    static func redirectRules(from rules: [[String: Any]], extensionID: String) -> [Rule] {
        var out: [(rule: Rule, id: Int)] = []
        for raw in rules {
            guard let action = raw["action"] as? [String: Any],
                  (action["type"] as? String) == "redirect",
                  let redirect = action["redirect"] as? [String: Any], !redirect.isEmpty else { continue }
            let condition = raw["condition"] as? [String: Any] ?? [:]

            // Must EXPLICITLY target main_frame (conservative — protects normal browsing).
            guard let resourceTypes = condition["resourceTypes"] as? [String],
                  resourceTypes.contains("main_frame") else { continue }
            // Skip anything with a domain/initiator condition we won't risk mis-evaluating.
            if condition["requestDomains"] != nil || condition["excludedRequestDomains"] != nil
                || condition["initiatorDomains"] != nil || condition["excludedInitiatorDomains"] != nil
                || condition["domains"] != nil || condition["excludedDomains"] != nil { continue }

            let caseSensitive = (condition["isUrlFilterCaseSensitive"] as? Bool) ?? false
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]

            let pattern: String
            var regexFilter: String?
            if let rf = condition["regexFilter"] as? String, !rf.isEmpty {
                pattern = rf
                regexFilter = rf
            } else if let uf = condition["urlFilter"] as? String, !uf.isEmpty {
                pattern = DeclarativeNetRequest.regex(fromURLFilter: uf)
            } else {
                continue   // no url condition → would match every navigation; refuse (over-match guard)
            }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }

            let priority = (raw["priority"] as? Int) ?? 1
            let id = (raw["id"] as? Int) ?? Int.max
            out.append((Rule(extensionID: extensionID, priority: priority, urlRegex: regex,
                             caseSensitive: caseSensitive, regexFilter: regexFilter, redirect: redirect), id))
        }
        // Highest priority first; tie → lower rule id first (DNR's documented precedence).
        out.sort { $0.rule.priority != $1.rule.priority ? $0.rule.priority > $1.rule.priority : $0.id < $1.id }
        return out.map(\.rule)
    }

    // MARK: - Match + target

    /// The redirect target for the first rule whose condition matches `url`, or nil if none match (or the
    /// best match resolves to a no-op/loop). `rules` must already be priority-ordered (redirectRules does).
    /// `extensionOrigin(extensionID)` maps an extension id to its `chrome-extension://<id>` origin (for
    /// the `extensionPath` redirect form). Pure — no I/O, fully unit-tested.
    static func target(for url: String, rules: [Rule], extensionOrigin: (String) -> String) -> URL? {
        let range = NSRange(url.startIndex..., in: url)
        for rule in rules {
            guard rule.urlRegex.firstMatch(in: url, range: range) != nil else { continue }
            guard let resolved = computeTarget(rule: rule, url: url, range: range,
                                               origin: extensionOrigin(rule.extensionID)) else { continue }
            // Loop/no-op guard: never divert a URL to itself (or to a non-http(s)/extension target).
            if resolved.absoluteString == url { return nil }
            return resolved
        }
        return nil
    }

    private static func computeTarget(rule: Rule, url: String, range: NSRange, origin: String) -> URL? {
        let redirect = rule.redirect
        if let staticURL = redirect["url"] as? String, !staticURL.isEmpty {
            return validatedTarget(staticURL)
        }
        if let path = redirect["extensionPath"] as? String, !path.isEmpty {
            let p = path.hasPrefix("/") ? path : "/" + path
            return URL(string: origin + p)
        }
        if let substitution = redirect["regexSubstitution"] as? String, let regexFilter = rule.regexFilter,
           let re = try? NSRegularExpression(pattern: regexFilter,
                                             options: rule.caseSensitive ? [] : [.caseInsensitive]) {
            // DNR regexSubstitution uses \0…\9 for capture groups; NSRegularExpression templates use $0…$9.
            let template = substitutionTemplate(from: substitution)
            let result = re.stringByReplacingMatches(in: url, range: range, withTemplate: template)
            return validatedTarget(result)
        }
        if let transform = redirect["transform"] as? [String: Any] {
            return applyTransform(transform, to: url)
        }
        return nil
    }

    /// Accept only an absolute http(s) or extension-scheme URL as a redirect target (never a javascript:,
    /// data:, etc. target an extension could abuse). Both chrome- and moz-extension count (Firefox builds).
    private static func validatedTarget(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
              || WebExtensionSchemeHandler.isExtensionScheme(scheme) else { return nil }
        return url
    }

    /// Convert a DNR regexSubstitution (`\1`, `\\` literal) to an NSRegularExpression template (`$1`).
    static func substitutionTemplate(from substitution: String) -> String {
        var out = ""
        var iterator = substitution.makeIterator()
        var pending: Character?
        func next() -> Character? { if let p = pending { pending = nil; return p }; return iterator.next() }
        while let ch = next() {
            if ch == "\\" {
                guard let after = next() else { out += "\\\\"; break }
                if after.isNumber { out += "$"; out.append(after) }     // \1 → $1
                else if after == "\\" { out += "\\\\" }                  // \\ → literal backslash
                else { out += "\\"; out.append(after) }
            } else if ch == "$" {
                out += "\\$"   // a literal $ in the substitution must be escaped for the template engine
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Apply a DNR `transform` to the source URL via URLComponents (scheme/host/port/path/query/fragment).
    /// `queryTransform` (add/remove params) is honored; an empty result is rejected upstream by the loop guard.
    private static func applyTransform(_ transform: [String: Any], to url: String) -> URL? {
        guard var components = URLComponents(string: url) else { return nil }
        if let scheme = transform["scheme"] as? String { components.scheme = scheme }
        if let host = transform["host"] as? String { components.host = host }
        if let port = transform["port"] as? String { components.port = Int(port) }    // "" clears → Int("")=nil
        if let path = transform["path"] as? String { components.path = path }
        if let fragment = transform["fragment"] as? String {
            components.fragment = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : (fragment.isEmpty ? nil : fragment)
        }
        if let query = transform["query"] as? String {
            components.query = query.hasPrefix("?") ? String(query.dropFirst()) : (query.isEmpty ? nil : query)
        } else if let qt = transform["queryTransform"] as? [String: Any] {
            applyQueryTransform(qt, to: &components)
        }
        guard let result = components.url, let scheme = result.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return result
    }

    private static func applyQueryTransform(_ qt: [String: Any], to components: inout URLComponents) {
        var items = components.queryItems ?? []
        if let remove = qt["removeParams"] as? [String] {
            let drop = Set(remove)
            items.removeAll { drop.contains($0.name) }
        }
        if let add = qt["addOrReplaceParams"] as? [[String: Any]] {
            for entry in add {
                guard let key = entry["key"] as? String else { continue }
                let value = entry["value"] as? String ?? ""
                if let idx = items.firstIndex(where: { $0.name == key }) { items[idx].value = value }
                else { items.append(URLQueryItem(name: key, value: value)) }
            }
        }
        components.queryItems = items.isEmpty ? nil : items
    }
}
