//
//  ScriptMetadata.swift
//  BrownBear
//
//  The parsed `// ==UserScript== … // ==/UserScript==` header. This is pure data — produced by
//  ScriptMetadataParser, consumed by URLMatcher (which directives to match) and the injection
//  bridge (which GM APIs are granted, when to run). Tampermonkey/Greasemonkey/Violentmonkey
//  compatible.
//

import Foundation

/// When a script's body should execute, mapped onto WebKit's injection timing.
/// `documentStart` → `WKUserScriptInjectionTime.atDocumentStart`; `documentEnd` →
/// `.atDocumentEnd`; `documentIdle` has no WebKit equivalent and is simulated by running at
/// the `window` load event (see brownbear-core.js).
enum RunAt: String, Codable, CaseIterable {
    case documentStart = "document-start"
    case documentEnd = "document-end"
    case documentIdle = "document-idle"

    /// Tampermonkey/Greasemonkey default when `@run-at` is absent.
    static let `default` = RunAt.documentEnd

    init(rawValueOrDefault raw: String) {
        self = RunAt(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .default
    }
}

/// The execution context a script is injected into.
enum InjectInto: String, Codable {
    case auto
    case content
    case page

    static let `default` = InjectInto.auto
}

/// Structured representation of a userscript's metadata block.
struct ScriptMetadata: Codable, Equatable {

    // Identity
    var name: String
    var namespace: String?
    var version: String?
    var descriptionText: String?
    var author: String?
    var homepageURL: String?
    var iconURL: String?
    /// Localized names keyed by locale, e.g. `@name:zh-CN` → ["zh-CN": "…"].
    var localizedNames: [String: String]

    // Matching directives
    var matches: [String]
    var includes: [String]
    var excludes: [String]
    var excludeMatches: [String]

    // Capabilities
    var grants: [String]
    var connects: [String]
    var requires: [String]
    /// Resource name → URL.
    var resources: [String: String]

    // Behavior
    var runAt: RunAt
    var injectInto: InjectInto
    var noFrames: Bool

    // Background execution (Module 4, ScriptCat-style)
    /// `@crontab` schedule expressions; a script with any runs in the background on schedule.
    var crontabs: [String]
    /// `@background` — a script that runs once when enabled/booted (no schedule).
    var isBackground: Bool

    /// The verbatim metadata block text, exposed to scripts as `GM_info.scriptMetaStr`.
    var metadataBlock: String

    init(name: String = "",
         namespace: String? = nil,
         version: String? = nil,
         descriptionText: String? = nil,
         author: String? = nil,
         homepageURL: String? = nil,
         iconURL: String? = nil,
         localizedNames: [String: String] = [:],
         matches: [String] = [],
         includes: [String] = [],
         excludes: [String] = [],
         excludeMatches: [String] = [],
         grants: [String] = [],
         connects: [String] = [],
         requires: [String] = [],
         resources: [String: String] = [:],
         runAt: RunAt = .default,
         injectInto: InjectInto = .default,
         noFrames: Bool = false,
         crontabs: [String] = [],
         isBackground: Bool = false,
         metadataBlock: String = "") {
        self.name = name
        self.namespace = namespace
        self.version = version
        self.descriptionText = descriptionText
        self.author = author
        self.homepageURL = homepageURL
        self.iconURL = iconURL
        self.localizedNames = localizedNames
        self.matches = matches
        self.includes = includes
        self.excludes = excludes
        self.excludeMatches = excludeMatches
        self.grants = grants
        self.connects = connects
        self.requires = requires
        self.resources = resources
        self.runAt = runAt
        self.injectInto = injectInto
        self.noFrames = noFrames
        self.crontabs = crontabs
        self.isBackground = isBackground
        self.metadataBlock = metadataBlock
    }

    // MARK: - Derived

    /// Whether the script declared `@grant none` (runs in page world with no GM APIs).
    var grantsNone: Bool {
        grants.count == 1 && grants.first?.lowercased() == "none"
    }

    /// The effective granted GM API names (empty if `@grant none`).
    var effectiveGrants: [String] {
        grantsNone ? [] : grants
    }

    /// A display name preferring `@name`, falling back to a placeholder.
    var displayName: String {
        name.isEmpty ? "Untitled Script" : name
    }

    /// Whether the script has any matching directive at all. A script with none never runs.
    var hasMatchingDirective: Bool {
        !(matches.isEmpty && includes.isEmpty)
    }

    /// Whether this script runs in the background (on a `@crontab` schedule or `@background`)
    /// rather than being injected into pages.
    var runsInBackground: Bool {
        !crontabs.isEmpty || isBackground
    }
}
