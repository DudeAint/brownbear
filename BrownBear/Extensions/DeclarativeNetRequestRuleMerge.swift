//
//  DeclarativeNetRequestRuleMerge.swift
//  BrownBear
//
//  The pure merge of an extension's three declarativeNetRequest rule sources into the single rule
//  list the WKContentRuleList compiler is fed:
//
//      enabled static rulesets  →  dynamic rules  →  session rules
//
//  Chrome treats a DNR rule's `id` as unique WITHIN a source but lets later runtime sources shadow a
//  static rule with the same id (dynamic/session rules are matched against the same id space). We
//  reproduce that with last-source-wins-by-id while preserving first-seen order, so the relative
//  ordering the static file declared is kept and a runtime override lands in the same slot. Rules
//  without an integer id (which the DNR compiler will skip anyway) are passed through verbatim so the
//  merge never silently drops input.
//
//  No WebKit, no persistence, no I/O — dictionaries in, a flat rule array out. Unit-tested.
//

import Foundation

enum DeclarativeNetRequestRuleMerge {

    /// Merge the three sources into one rule array, later sources overriding earlier ones by `id`.
    /// Order: static rules (in declared order) first, then any dynamic/session ids not seen in an
    /// earlier source, then id-less rules in source order. A same-id rule keeps the EARLIEST slot but
    /// takes the LATEST source's body — matching Chrome, where a dynamic/session rule supersedes the
    /// static rule that shares its id.
    static func merge(staticRules: [[String: Any]],
                      dynamicRules: [[String: Any]],
                      sessionRules: [[String: Any]]) -> [[String: Any]] {
        var bodyForID: [Int: [String: Any]] = [:]
        var order: [Int] = []
        var anonymous: [[String: Any]] = []

        func absorb(_ rules: [[String: Any]]) {
            for rule in rules {
                guard let id = rule["id"] as? Int else { anonymous.append(rule); continue }
                if bodyForID[id] == nil { order.append(id) }
                bodyForID[id] = rule   // later source wins; slot (in `order`) stays at first sighting
            }
        }
        absorb(staticRules)
        absorb(dynamicRules)
        absorb(sessionRules)

        var merged: [[String: Any]] = []
        merged.reserveCapacity(order.count + anonymous.count)
        for id in order {
            if let body = bodyForID[id] { merged.append(body) }
        }
        merged.append(contentsOf: anonymous)
        return merged
    }
}
