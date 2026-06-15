//
//  StaticPageWorldInjector.swift
//  BrownBear
//
//  INJ-A: TRUE document-start injection for grant-none page-world userscripts (the "as great as
//  Violentmonkey" timing win). Builds a single `.page`, atDocumentStart `WKUserScript` whose source is
//  `var __bbStaticCfg = <JSON of eligible scripts>;` + brownbear-pageworld-static.js, so each matching
//  script runs at the page's ACTUAL document-start (before any page script) — like a VM static
//  content_script — instead of after the getScripts round-trip.
//
//  Eligibility is deliberately narrow + conservative (so it can never regress or mis-inject):
//   • @grant none (page world, NO GM bridge → none of the cross-world rendezvous #177 broke is touched),
//   • @inject-into page or auto (not content),
//   • @run-at document-start (the only run-at the timing win applies to),
//   • no @require (the static path can't await asset inlining; @require scripts keep the dynamic path),
//   • not @noframes (one all-frames WKUserScript in v1; noframes scripts keep the dynamic path),
//   • has a @match/@include (the JS matcher — proven 45/45 vs URLMatcherTests — gates each at runtime).
//  Everything else falls back to the existing dynamic path, which the shared run-once guard
//  (window.__bbRanUS[uuid], in buildPageWorldSource) makes safe: whichever path fires first runs the
//  script; the other skips. A strict-CSP page that refuses the static eval also falls back (the guard
//  never ran), so there is no double-run and no miss.
//

import WebKit

enum StaticPageWorldInjector {

    /// Whether a script qualifies for the static document-start fast-path. See the file header.
    static func isEligible(_ script: UserScript) -> Bool {
        let meta = script.metadata
        return meta.grantsNone
            && script.effectiveInjectInto != .content
            && script.effectiveRunAt == .documentStart
            && meta.requires.isEmpty
            && !meta.noFrames
            && !(meta.matches.isEmpty && meta.includes.isEmpty)
    }

    /// The static `WKUserScript`(s) for the eligible scripts among `scripts`, or `[]` if none qualify.
    /// `staticJS` is the bundled brownbear-pageworld-static.js source. Pure — no WebKit/session state.
    static func userScripts(from scripts: [UserScript],
                            isIncognito: Bool,
                            staticJS: String) -> [WKUserScript] {
        let eligible = scripts.filter(isEligible)
        guard !eligible.isEmpty else { return [] }

        let cfg: [[String: Any]] = eligible.map { script in
            let meta = script.metadata
            return [
                "uuid": script.id.uuidString,
                "matches": meta.matches,
                "includes": meta.includes,
                "excludes": meta.excludes,
                "excludeMatches": meta.excludeMatches,
                "info": ScriptMessageRouter.pageWorldGMInfo(for: script, isIncognito: isIncognito),
                "source": script.executableBody
            ]
        }
        guard JSONSerialization.isValidJSONObject(cfg),
              let data = try? JSONSerialization.data(withJSONObject: cfg),
              let json = String(data: data, encoding: .utf8) else {
            return []
        }
        let source = "var __bbStaticCfg = \(json);\n" + staticJS
        // All-frames: noframes scripts were excluded above, so every eligible script wants subframes too.
        return [WKUserScript(source: source,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false,
                             in: .page)]
    }
}
