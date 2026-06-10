//
//  WebExtensionLocalizer.swift
//  BrownBear
//
//  Resolves Chrome i18n `__MSG_name__` placeholders that appear in manifest fields — most visibly the
//  `name` and `description`, which is why a localized extension would otherwise show up in our UI as the
//  literal "__MSG_appName__" / "__MSG_title__". Chrome substitutes these against the default locale's
//  `_locales/<default_locale>/messages.json` before the manifest is ever shown, and also understands the
//  `@@`-prefixed predefined messages (notably `@@extension_id` and `@@ui_locale`).
//
//  These resolutions feed synchronous UI (list rows, menu labels, blocker reports), so the messages.json
//  is read synchronously off the store's immutable package tree (`fileSync`) and cached per extension id.
//  An install gets a fresh id, so the cache never goes stale for the life of an install.
//

import Foundation

enum WebExtensionLocalizer {

    /// extensionID → (messageKey.lowercased() → message). `NSCache` is thread-safe, so the resolver is
    /// safe to call from any thread/actor. A missing entry is computed on first use.
    private static let cache = NSCache<NSString, NSDictionary>()

    /// A sentinel stored for extensions that have no resolvable messages, so we don't re-hit the disk on
    /// every `displayName` read for an unlocalized extension.
    private static let emptyMarker: NSDictionary = ["__bb_empty__": ""]

    /// Resolve every `__MSG_*__` placeholder in `raw`. Unresolved placeholders fall back to a humanized
    /// form of the key (so the user never sees the raw `__MSG_…__` token) rather than Chrome's
    /// install-time hard failure — we favour showing *something* legible.
    static func resolve(_ raw: String, extensionID: String, defaultLocale: String?) -> String {
        guard raw.contains("__MSG_") else { return raw }
        let messages = messages(extensionID: extensionID, defaultLocale: defaultLocale)
        return substitute(raw, extensionID: extensionID, defaultLocale: defaultLocale, messages: messages)
    }

    /// Drop the cached messages for an extension (call on uninstall / reinstall under the same id, e.g.
    /// an update-in-place). Harmless if absent.
    static func invalidate(extensionID: String) {
        cache.removeObject(forKey: extensionID as NSString)
    }

    /// Extract the NAMED-placeholder map from a parsed `messages.json`: messageKey (verbatim) →
    /// (placeholderName.lowercased → content). A Chrome i18n message may declare named placeholders —
    /// e.g. `"message": "$NAME$ $VERSION$ is available"` + `"placeholders": {"name": {"content": "$1"},
    /// "version": {"content": "$2"}}`. `getMessage` substitutes `$name$`/`$version$` with their content
    /// (which is then positional `$1..$9`). The flattened {key:string} message map the shims get for
    /// `__MSG_*__` manifest resolution DROPS these, so without this parallel map the page leaks the
    /// literal `$version$`. Keys are kept verbatim so a shim's `getMessage(key)` lookup matches the
    /// extension's exact key (placeholder NAMES are matched case-insensitively, per Chrome).
    static func extractPlaceholders(fromMessagesJSON json: [String: Any]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (key, value) in json {
            guard let entry = value as? [String: Any],
                  let placeholders = entry["placeholders"] as? [String: Any] else { continue }
            var map: [String: String] = [:]
            for (name, raw) in placeholders {
                if let dict = raw as? [String: Any], let content = dict["content"] as? String {
                    map[name.lowercased()] = content
                }
            }
            if !map.isEmpty { out[key] = map }
        }
        return out
    }

    // MARK: - Substitution

    /// Pure placeholder substitution against an explicit message map (keys lowercased). Exposed at
    /// `internal` for table-driven tests; production callers go through `resolve`.
    static func substitute(_ raw: String, extensionID: String,
                           defaultLocale: String?, messages: [String: String]) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        let scalars = Array(raw)
        var i = 0
        let marker = Array("__MSG_")
        while i < scalars.count {
            if matches(scalars, at: i, marker) {
                let keyStart = i + marker.count
                if let keyEnd = closingIndex(scalars, from: keyStart) {
                    let key = String(scalars[keyStart..<keyEnd])
                    result += replacement(forKey: key, extensionID: extensionID,
                                          defaultLocale: defaultLocale, messages: messages)
                    i = keyEnd + 2   // skip the trailing "__"
                    continue
                }
            }
            result.append(scalars[i])
            i += 1
        }
        return result
    }

    /// The closing `__` index (index of the first `_` of the pair) for a placeholder key that began at
    /// `start`, or nil if the token is malformed. Keys are `[@A-Za-z0-9_]`, but a lone `_` is only a
    /// terminator when immediately followed by another `_`.
    private static func closingIndex(_ scalars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < scalars.count {
            if scalars[j] == "_" && scalars[j + 1] == "_" {
                return j > start ? j : nil   // require a non-empty key
            }
            let c = scalars[j]
            guard c == "@" || c == "_" || c.isLetter || c.isNumber else { return nil }
            j += 1
        }
        return nil
    }

    private static func matches(_ scalars: [Character], at index: Int, _ needle: [Character]) -> Bool {
        guard index + needle.count <= scalars.count else { return false }
        for k in 0..<needle.count where scalars[index + k] != needle[k] { return false }
        return true
    }

    private static func replacement(forKey key: String, extensionID: String,
                                    defaultLocale: String?, messages: [String: String]) -> String {
        // Predefined messages (Chrome): referenced as __MSG_@@name__.
        switch key {
        case "@@extension_id":
            return extensionID
        case "@@ui_locale":
            return defaultLocale ?? Locale.current.identifier
        case "@@bidi_dir":
            return isRTL(defaultLocale) ? "rtl" : "ltr"
        case "@@bidi_reversed_dir":
            return isRTL(defaultLocale) ? "ltr" : "rtl"
        case "@@bidi_start_edge":
            return isRTL(defaultLocale) ? "right" : "left"
        case "@@bidi_end_edge":
            return isRTL(defaultLocale) ? "left" : "right"
        default:
            if let message = messages[key.lowercased()] { return message }
            return humanize(key)
        }
    }

    /// Last-resort label for a placeholder whose message is missing: "appName" → "App Name". Keeps the
    /// UI legible instead of surfacing the raw token the user reported.
    private static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        var out = ""
        var previousLower = false
        for ch in spaced {
            if ch.isUppercase && previousLower { out.append(" ") }
            out.append(ch)
            previousLower = ch.isLowercase || ch.isNumber
        }
        return out.split(separator: " ").map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func isRTL(_ locale: String?) -> Bool {
        guard let locale else { return false }
        let language = locale.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? locale
        return ["ar", "fa", "he", "iw", "ur", "ps", "sd", "ug", "yi"].contains(language.lowercased())
    }

    // MARK: - Message loading

    private static func messages(extensionID: String, defaultLocale: String?) -> [String: String] {
        if let cached = cache.object(forKey: extensionID as NSString) {
            if cached === emptyMarker { return [:] }
            return (cached as? [String: String]) ?? [:]
        }
        let loaded = loadFromDisk(extensionID: extensionID, defaultLocale: defaultLocale)
        cache.setObject(loaded.isEmpty ? emptyMarker : (loaded as NSDictionary),
                        forKey: extensionID as NSString)
        return loaded
    }

    /// Read `_locales/<default_locale>/messages.json` and flatten it to lowercased-key → message. Tries
    /// the manifest's declared default locale first, then a couple of common fallbacks, so an extension
    /// that omitted `default_locale` but shipped `_locales/en` still resolves.
    private static func loadFromDisk(extensionID: String, defaultLocale: String?) -> [String: String] {
        let store = BrownBearServices.shared.webExtensionStore
        var candidates: [String] = []
        if let defaultLocale, !defaultLocale.isEmpty { candidates.append(defaultLocale) }
        candidates.append(contentsOf: ["en", "en_US", "en_GB"])
        var seen = Set<String>()
        for locale in candidates where seen.insert(locale).inserted {
            guard let data = store.fileSync(extensionID: extensionID,
                                            path: "_locales/\(locale)/messages.json"),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            var out: [String: String] = [:]
            for (key, value) in json {
                if let entry = value as? [String: Any], let message = entry["message"] as? String {
                    out[key.lowercased()] = message
                }
            }
            if !out.isEmpty { return out }
        }
        return [:]
    }
}
