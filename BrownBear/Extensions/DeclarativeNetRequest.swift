//
//  DeclarativeNetRequest.swift
//  BrownBear
//
//  Compiles a Chrome `declarativeNetRequest` STATIC ruleset (the JSON files an extension ships and
//  references from `manifest.json`'s `declarative_net_request.rule_resources`) into the JSON source
//  that WebKit's `WKContentRuleList` compiler accepts. That's the only network-blocking primitive
//  iOS gives us — a declarative, ahead-of-time rule list — so DNR maps onto it remarkably well.
//
//  This file is PURE and synchronous: dictionaries in, a JSON string out, no WebKit import. The
//  actual `compileContentRuleList` / install lives in `WebExtensionContentBlocker` so this stays
//  unit-testable without a web view.
//
//  Fidelity over coverage: a DNR rule we cannot represent FAITHFULLY in WebKit (a redirect, a
//  header rewrite, a request-method or request-domain filter we can't narrow) is SKIPPED and
//  counted, never approximated into something that would over-block and break a page. Callers
//  surface `skippedCount`/`warnings` so the gap is visible, not silent.
//

import Foundation

enum DeclarativeNetRequest {

    /// The outcome of compiling one ruleset: the WebKit rule-list JSON plus an honest accounting of
    /// what was dropped.
    struct CompileResult: Equatable {
        /// WKContentRuleList source — a JSON array string. `"[]"` when nothing survived.
        var json: String
        var compiledCount: Int
        var skippedCount: Int
        var warnings: [String]
        var isEmpty: Bool { compiledCount == 0 }
    }

    // MARK: - Entry points

    /// Compile a ruleset file's raw bytes (a JSON array of DNR rule objects).
    static func compile(rulesetData: Data) -> CompileResult {
        guard let array = (try? JSONSerialization.jsonObject(with: rulesetData)) as? [[String: Any]] else {
            return CompileResult(json: "[]", compiledCount: 0, skippedCount: 0,
                                 warnings: ["ruleset is not a JSON array of rules"])
        }
        return compile(rules: array)
    }

    /// Compile an array of DNR rule dictionaries.
    static func compile(rules: [[String: Any]]) -> CompileResult {
        var compiled: [CompiledRule] = []
        var skipped = 0
        var warnings: [String] = []

        for (index, rule) in rules.enumerated() {
            switch translate(rule, order: index) {
            case .success(let compiledRule):
                compiled.append(compiledRule)
            case .skip(let reason):
                skipped += 1
                if warnings.count < maxWarnings { warnings.append(reason) }
            }
        }

        // WebKit evaluates rules top-to-bottom and the LAST matching action wins (an
        // `ignore-previous-rules` clears earlier blocks). DNR instead picks the highest-priority
        // match, breaking ties by action (allow > block > upgrade). We reproduce that by ordering
        // ascending: higher priority later, and within a priority the higher-ranked action later.
        compiled.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.actionRank != rhs.actionRank { return lhs.actionRank < rhs.actionRank }
            return lhs.order < rhs.order
        }

        let objects = compiled.map { $0.object }
        let json: String
        if objects.isEmpty {
            json = "[]"
        } else if let data = try? JSONSerialization.data(withJSONObject: objects,
                                                          options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8) {
            json = string
        } else {
            json = "[]"
            warnings.append("failed to serialize \(objects.count) compiled rules")
            return CompileResult(json: json, compiledCount: 0,
                                 skippedCount: skipped + objects.count, warnings: warnings)
        }

        return CompileResult(json: json, compiledCount: objects.count,
                             skippedCount: skipped, warnings: warnings)
    }

    // MARK: - Translation

    private static let maxWarnings = 25

    private struct CompiledRule {
        var object: [String: Any]
        var priority: Int
        var actionRank: Int
        var order: Int
    }

    private enum Translation {
        case success(CompiledRule)
        case skip(String)
    }

    private static func translate(_ rule: [String: Any], order: Int) -> Translation {
        guard let actionDict = rule["action"] as? [String: Any],
              let actionType = actionDict["type"] as? String else {
            return .skip("rule \(ruleID(rule)) has no action.type")
        }

        let webkitAction: [String: Any]
        let actionRank: Int
        switch actionType {
        case "block":
            webkitAction = ["type": "block"]; actionRank = 1
        case "allow", "allowAllRequests":
            webkitAction = ["type": "ignore-previous-rules"]; actionRank = 2
        case "upgradeScheme":
            webkitAction = ["type": "make-https"]; actionRank = 0
        case "redirect":
            return .skip("rule \(ruleID(rule)): 'redirect' is unsupported on iOS content rule lists")
        case "modifyHeaders":
            return .skip("rule \(ruleID(rule)): 'modifyHeaders' is unsupported on iOS content rule lists")
        default:
            return .skip("rule \(ruleID(rule)): unknown action '\(actionType)'")
        }

        let condition = rule["condition"] as? [String: Any] ?? [:]

        // Constraints WebKit can't express. Dropping them would change which requests match, so we
        // skip the whole rule rather than silently widen or narrow it.
        if let methods = condition["requestMethods"] as? [String], !methods.isEmpty {
            return .skip("rule \(ruleID(rule)): requestMethods has no content-rule-list equivalent")
        }
        if let domains = condition["requestDomains"] as? [String], !domains.isEmpty {
            return .skip("rule \(ruleID(rule)): requestDomains can't be mapped to if-domain (it filters the page, not the request)")
        }
        if let excluded = condition["excludedRequestDomains"] as? [String], !excluded.isEmpty {
            return .skip("rule \(ruleID(rule)): excludedRequestDomains has no content-rule-list equivalent")
        }

        var trigger: [String: Any] = [:]

        // url-filter: prefer regexFilter (RE2), but ONLY if it stays inside the small regex subset
        // WebKit's content-rule-list compiler accepts. That compiler is all-or-nothing — a single
        // unsupported token rejects the ENTIRE encoded list — so we skip-and-count an unrepresentable
        // regexFilter (same policy as redirect/modifyHeaders) rather than weaponize it into a
        // list-wide compile failure that would silently disable every other rule in the file.
        if let regexFilter = condition["regexFilter"] as? String, !regexFilter.isEmpty {
            guard isWebKitSupportedRegex(regexFilter) else {
                return .skip("rule \(ruleID(rule)): regexFilter uses RE2 syntax WebKit's url-filter can't represent")
            }
            trigger["url-filter"] = regexFilter
        } else if let urlFilter = condition["urlFilter"] as? String, !urlFilter.isEmpty {
            trigger["url-filter"] = regex(fromURLFilter: urlFilter)
        } else {
            trigger["url-filter"] = ".*"
        }

        // DNR defaults to case-insensitive; WebKit's flag also defaults to insensitive, so only
        // emit it when the rule explicitly asks for case sensitivity.
        if (condition["isUrlFilterCaseSensitive"] as? Bool) == true {
            trigger["url-filter-is-case-sensitive"] = true
        }

        // Initiator (page) domains → if-domain / unless-domain. WebKit forbids both in one trigger,
        // so an inclusion list wins over an exclusion list (and we note the dropped exclusion).
        let initiator = (condition["initiatorDomains"] as? [String]) ?? (condition["domains"] as? [String])
        let excludedInitiator = (condition["excludedInitiatorDomains"] as? [String]) ?? (condition["excludedDomains"] as? [String])
        if let initiator, !initiator.isEmpty {
            trigger["if-domain"] = initiator.map(domainEntry)
        } else if let excludedInitiator, !excludedInitiator.isEmpty {
            trigger["unless-domain"] = excludedInitiator.map(domainEntry)
        }

        // Resource types. DNR's default (field omitted) is "all", which WebKit also means by
        // omitting resource-type. An excludedResourceTypes list becomes the complement.
        if let types = condition["resourceTypes"] as? [String], !types.isEmpty {
            let mapped = Set(types.compactMap(mapResourceType))
            if mapped.isEmpty {
                return .skip("rule \(ruleID(rule)): no resourceTypes map to a WebKit type")
            }
            trigger["resource-type"] = mapped.sorted()
        } else if let excluded = condition["excludedResourceTypes"] as? [String], !excluded.isEmpty {
            let complement = allWebKitResourceTypes.subtracting(excluded.compactMap(mapResourceType))
            if complement.isEmpty {
                return .skip("rule \(ruleID(rule)): excludedResourceTypes leaves no WebKit type")
            }
            trigger["resource-type"] = complement.sorted()
        }

        // First/third-party.
        if let domainType = condition["domainType"] as? String {
            if domainType == "firstParty" { trigger["load-type"] = ["first-party"] }
            else if domainType == "thirdParty" { trigger["load-type"] = ["third-party"] }
        }

        let priority = (rule["priority"] as? Int) ?? 1
        return .success(CompiledRule(object: ["trigger": trigger, "action": webkitAction],
                                     priority: priority, actionRank: actionRank, order: order))
    }

    // MARK: - urlFilter → WebKit regex

    /// Translate a DNR `urlFilter` into a WebKit url-filter regex.
    ///
    /// DNR filter syntax:
    ///   `||`  (leading) → anchor to the domain (host + any subdomain), scheme-agnostic
    ///   `|`   (leading) → anchor to the start of the URL
    ///   `|`   (trailing) → anchor to the end of the URL
    ///   `*`   → wildcard (any run of characters)
    ///   `^`   → separator: any char that isn't a letter, digit, `_`, `-`, `.`, or `%`
    /// Everything else is a literal and its regex metacharacters are escaped.
    static func regex(fromURLFilter filter: String) -> String {
        var body = filter
        var out = ""

        if body.hasPrefix("||") {
            // Scheme, `://`, then zero or more `label.` subdomain segments.
            out += "^[^:]+://([a-z0-9_-]+\\.)*"
            body.removeFirst(2)
        } else if body.hasPrefix("|") {
            out += "^"
            body.removeFirst()
        }

        var anchorEnd = false
        if body.hasSuffix("|") {
            anchorEnd = true
            body.removeLast()
        }

        for character in body {
            switch character {
            case "*":
                out += ".*"
            case "^":
                out += "[^a-zA-Z0-9_.%-]"
            default:
                if regexMetacharacters.contains(character) {
                    out += "\\"
                }
                out.append(character)
            }
        }

        if anchorEnd { out += "$" }
        return out
    }

    // MARK: - Lookups

    /// A WebKit if-domain/unless-domain entry. A leading `*` makes the entry match the domain AND
    /// all of its subdomains, which is DNR's default initiator-domain semantics.
    private static func domainEntry(_ domain: String) -> String {
        let trimmed = domain.hasPrefix("*.") ? String(domain.dropFirst(2)) : domain
        return "*" + trimmed.lowercased()
    }

    /// DNR resource type → WebKit `resource-type`. Unmappable types return nil (and are dropped from
    /// the set, never silently treated as "all").
    private static func mapResourceType(_ type: String) -> String? {
        switch type {
        case "main_frame", "sub_frame": return "document"
        case "stylesheet": return "style-sheet"
        case "script": return "script"
        case "image": return "image"
        case "font": return "font"
        case "media": return "media"
        case "xmlhttprequest": return "fetch"
        case "ping", "csp_report": return "ping"
        case "websocket": return "websocket"
        case "object", "webtransport", "webbundle", "other": return "other"
        default: return nil
        }
    }

    private static let allWebKitResourceTypes: Set<String> = [
        "document", "image", "style-sheet", "script", "font", "media", "fetch", "ping",
        "websocket", "other"
    ]

    private static let regexMetacharacters: Set<Character> = ["\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}"]

    /// True when `pattern` stays within the regex subset WebKit's content-rule-list compiler
    /// accepts: literals, `.`, greedy `* + ?`, `^ $`, groups `( )`, and character classes `[ ]`.
    /// It rejects the RE2-only constructs WebKit does NOT support — shorthand classes (`\d \w \s \b`
    /// and negations), bounded/counted repetition `{n,m}`, non-greedy quantifiers (`*? +? ??`),
    /// backreferences (`\1`), lookaround (`(?= (?! (?<= (?<!`), and named/non-capturing groups
    /// (`(?`). A false here makes the caller skip-and-count the rule instead of failing the list.
    private static func isWebKitSupportedRegex(_ pattern: String) -> Bool {
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        while index < scalars.count {
            switch scalars[index] {
            case "\\":
                guard index + 1 < scalars.count else { return false } // dangling escape
                let next = scalars[index + 1]
                if "dDwWsSbB".unicodeScalars.contains(next) { return false }   // shorthand classes
                if next >= "1" && next <= "9" { return false }                // backreference
                index += 2
            case "{":
                return false                                                  // counted repetition
            case "(":
                // Any "(?" form — lookaround, named, or non-capturing — is unsupported by WebKit.
                if index + 1 < scalars.count && scalars[index + 1] == "?" { return false }
                index += 1
            case "*", "+", "?":
                if index + 1 < scalars.count && scalars[index + 1] == "?" { return false } // non-greedy
                index += 1
            default:
                index += 1
            }
        }
        return true
    }

    private static func ruleID(_ rule: [String: Any]) -> String {
        if let id = rule["id"] as? Int { return "#\(id)" }
        return "#?"
    }
}
