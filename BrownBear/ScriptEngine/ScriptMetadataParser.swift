//
//  ScriptMetadataParser.swift
//  BrownBear
//
//  Parses the `// ==UserScript== … // ==/UserScript==` block into ScriptMetadata. The grammar
//  mirrors the established managers (quoid/userscripts' Functions.swift and scriptcat's
//  script.ts): a header block delimited by the UserScript markers, then `// @key value` lines
//  where the key may carry a `:locale` suffix and some keys (e.g. @noframes) are valueless
//  flags. Multi-valued keys (@match, @grant, …) accumulate. Pure logic — fully unit-tested.
//

import Foundation

struct ScriptMetadataParser {

    /// Keys that may appear multiple times and accumulate into arrays.
    private static let multiValueKeys: Set<String> = [
        "match", "include", "exclude", "exclude-match",
        "grant", "connect", "require", "resource", "antifeature", "crontab"
    ]

    /// Detects the metadata block. `(?s)` lets `.` span newlines; CRLF tolerated.
    private static let blockRegex = makeRegex(
        #"(?s)//[ \t]*==UserScript==[ \t]*\r?\n(.*?)\r?\n[ \t]*//[ \t]*==/UserScript=="#
    )

    /// A single `// @key value` line. Group 1 = key (word chars, `:`, `-`); group 2 = value.
    private static let lineRegex = makeRegex(
        #"(?m)^[ \t]*//[ \t]*@([\w:-]+)[ \t]*(.*?)[ \t]*$"#
    )

    /// Parse `source` into metadata.
    /// - Throws: `BrownBearError.metadataParseFailed` if the block is absent or `@name` missing.
    func parse(_ source: String) throws -> ScriptMetadata {
        guard let blockRegex = Self.blockRegex, let lineRegex = Self.lineRegex else {
            throw BrownBearError.metadataParseFailed("internal regex unavailable")
        }

        let fullRange = NSRange(source.startIndex..., in: source)
        guard let blockMatch = blockRegex.firstMatch(in: source, range: fullRange),
              let blockRange = Range(blockMatch.range(at: 1), in: source) else {
            throw BrownBearError.metadataParseFailed("no ==UserScript== metadata block found")
        }

        let blockText = String(source[blockRange])
        var metadata = ScriptMetadata()
        metadata.metadataBlock = blockText

        let blockNSRange = NSRange(blockText.startIndex..., in: blockText)
        lineRegex.enumerateMatches(in: blockText, range: blockNSRange) { match, _, _ in
            guard let match,
                  let keyRange = Range(match.range(at: 1), in: blockText) else { return }
            let key = blockText[keyRange].lowercased()
            let value: String
            if match.range(at: 2).location != NSNotFound,
               let valueRange = Range(match.range(at: 2), in: blockText) {
                value = String(blockText[valueRange]).trimmingCharacters(in: .whitespaces)
            } else {
                value = ""
            }
            Self.apply(key: key, value: value, to: &metadata)
        }

        guard !metadata.name.isEmpty else {
            throw BrownBearError.metadataParseFailed("@name is required")
        }
        return metadata
    }

    // MARK: - Key dispatch

    private static func apply(key rawKey: String, value: String, to meta: inout ScriptMetadata) {
        // Split a possible localization suffix: `name:zh-CN` → ("name", "zh-CN").
        let parts = rawKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0])
        let locale = parts.count > 1 ? String(parts[1]) : nil

        switch key {
        case "name":
            if let locale { meta.localizedNames[locale] = value } else { meta.name = value }
        case "namespace": meta.namespace = value
        case "version": meta.version = value
        case "description":
            if locale == nil { meta.descriptionText = value }
        case "author": meta.author = value
        case "homepage", "homepageurl", "website", "source":
            meta.homepageURL = value
        case "icon", "iconurl", "defaulticon":
            meta.iconURL = value

        case "match" where !value.isEmpty: meta.matches.append(value)
        case "include" where !value.isEmpty: meta.includes.append(value)
        case "exclude" where !value.isEmpty: meta.excludes.append(value)
        case "exclude-match" where !value.isEmpty: meta.excludeMatches.append(value)

        case "grant" where !value.isEmpty: meta.grants.append(value)
        case "connect" where !value.isEmpty: meta.connects.append(value)
        case "require" where !value.isEmpty: meta.requires.append(value)
        case "resource" where !value.isEmpty:
            // `@resource name url` — two whitespace-separated tokens.
            let tokens = value.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.count == 2 {
                meta.resources[String(tokens[0])] = String(tokens[1]).trimmingCharacters(in: .whitespaces)
            }

        case "run-at": meta.runAt = RunAt(rawValueOrDefault: value)
        case "inject-into":
            meta.injectInto = InjectInto(rawValue: value.lowercased()) ?? .default
        case "noframes": meta.noFrames = true
        case "crontab" where !value.isEmpty: meta.crontabs.append(value)
        case "background": meta.isBackground = true

        default:
            break // Unknown / unsupported keys are ignored, not fatal.
        }
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}
