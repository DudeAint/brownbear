//
//  WebExtensionManifest.swift
//  BrownBear
//
//  Parses a browser-extension `manifest.json` (manifest_version 2 AND 3) into a normalized model.
//  Manifests are famously inconsistent (polymorphic fields differ MV2↔MV3), so we parse from a
//  loose JSON dictionary and normalize, rather than relying on rigid Codable. Pure logic — tested.
//

import Foundation

struct WebExtensionManifest: Equatable {

    struct ContentScript: Equatable {
        var matches: [String]
        var excludeMatches: [String]
        var includeGlobs: [String]
        var excludeGlobs: [String]
        var js: [String]
        var css: [String]
        var runAt: String          // document_start | document_end | document_idle
        var allFrames: Bool
        var matchAboutBlank: Bool
        var world: String?         // ISOLATED | MAIN (MV3)
    }

    struct Background: Equatable {
        var scripts: [String]
        var page: String?
        var serviceWorker: String?
        var persistent: Bool?
        var isModule: Bool
    }

    struct Action: Equatable {
        var defaultTitle: String?
        var defaultPopup: String?
        var defaultIcon: [String: String]   // size → path (a bare string is stored under "0")
    }

    struct WebAccessibleResource: Equatable {
        var resources: [String]
        var matches: [String]
    }

    /// A declarativeNetRequest static ruleset: a JSON file of block/allow/redirect rules the
    /// extension ships, which we compile to a WKContentRuleList. (`declarative_net_request`.)
    struct DNRRuleset: Equatable {
        var id: String
        var enabled: Bool
        var path: String
    }

    /// A keyboard `command` the extension declares (MV2/MV3). We surface them so the runtime can
    /// dispatch `chrome.commands.onCommand`; the reserved `_execute_action` opens the popup.
    struct Command: Equatable {
        var name: String
        var suggestedKey: String?
        var description: String?
    }

    // Identity
    var manifestVersion: Int
    var name: String
    var version: String
    var descriptionText: String?
    var defaultLocale: String?
    var icons: [String: String]

    // Behavior
    var contentScripts: [ContentScript]
    var background: Background?
    var action: Action?
    var permissions: [String]
    var hostPermissions: [String]
    var optionalPermissions: [String]
    var webAccessibleResources: [WebAccessibleResource]
    var optionsPage: String?
    var optionsOpenInTab: Bool
    var contentSecurityPolicy: String?
    var declarativeNetRequest: [DNRRuleset]
    var commands: [Command]

    // MARK: - Derived

    /// Host match patterns the extension may act on (declared host perms + content-script matches).
    var effectiveHostPatterns: [String] {
        var patterns = Set(hostPermissions)
        for script in contentScripts { patterns.formUnion(script.matches) }
        return Array(patterns)
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> WebExtensionManifest {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BrownBearError.metadataParseFailed("manifest.json is not a JSON object")
        }
        return try parse(json)
    }

    static func parse(_ json: [String: Any]) throws -> WebExtensionManifest {
        let manifestVersion = (json["manifest_version"] as? Int) ?? 2
        guard let name = json["name"] as? String, !name.isEmpty else {
            throw BrownBearError.metadataParseFailed("manifest is missing \"name\"")
        }
        guard let version = json["version"] as? String, !version.isEmpty else {
            throw BrownBearError.metadataParseFailed("manifest is missing \"version\"")
        }

        let icons = (json["icons"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]

        let contentScripts = (json["content_scripts"] as? [[String: Any]] ?? []).map(parseContentScript)
        let background = (json["background"] as? [String: Any]).map(parseBackground)
        let actionDict = (json["action"] ?? json["browser_action"] ?? json["page_action"]) as? [String: Any]
        let action = actionDict.map(parseAction)

        // Permissions: in MV2 the permissions array mixes API permissions and host match patterns;
        // split host patterns out so the model matches MV3's host_permissions.
        let rawPermissions = stringArray(json["permissions"])
        var permissions: [String] = []
        var hostPermissions = stringArray(json["host_permissions"])
        if manifestVersion >= 3 {
            permissions = rawPermissions
        } else {
            for permission in rawPermissions {
                if isHostPattern(permission) { hostPermissions.append(permission) } else { permissions.append(permission) }
            }
        }

        let war = parseWebAccessibleResources(json["web_accessible_resources"])

        var optionsPage: String?
        var optionsOpenInTab = false
        if let optionsUI = json["options_ui"] as? [String: Any] {
            optionsPage = optionsUI["page"] as? String
            optionsOpenInTab = (optionsUI["open_in_tab"] as? Bool) ?? false
        } else if let page = json["options_page"] as? String {
            optionsPage = page
            optionsOpenInTab = true
        }

        let csp: String?
        if let cspString = json["content_security_policy"] as? String {
            csp = cspString
        } else if let cspObject = json["content_security_policy"] as? [String: Any] {
            csp = cspObject["extension_pages"] as? String
        } else {
            csp = nil
        }

        let dnr = parseDNRRulesets(json["declarative_net_request"])
        let commands = parseCommands(json["commands"])

        return WebExtensionManifest(
            manifestVersion: manifestVersion,
            name: name,
            version: version,
            descriptionText: json["description"] as? String,
            defaultLocale: json["default_locale"] as? String,
            icons: icons,
            contentScripts: contentScripts,
            background: background,
            action: action,
            permissions: permissions,
            hostPermissions: hostPermissions,
            optionalPermissions: stringArray(json["optional_permissions"]),
            webAccessibleResources: war,
            optionsPage: optionsPage,
            optionsOpenInTab: optionsOpenInTab,
            contentSecurityPolicy: csp,
            declarativeNetRequest: dnr,
            commands: commands)
    }

    // MARK: - Field parsers

    private static func parseContentScript(_ dict: [String: Any]) -> ContentScript {
        ContentScript(
            matches: stringArray(dict["matches"]),
            excludeMatches: stringArray(dict["exclude_matches"]),
            includeGlobs: stringArray(dict["include_globs"]),
            excludeGlobs: stringArray(dict["exclude_globs"]),
            js: stringArray(dict["js"]),
            css: stringArray(dict["css"]),
            runAt: (dict["run_at"] as? String) ?? "document_idle",
            allFrames: (dict["all_frames"] as? Bool) ?? false,
            matchAboutBlank: (dict["match_about_blank"] as? Bool) ?? false,
            world: dict["world"] as? String)
    }

    private static func parseBackground(_ dict: [String: Any]) -> Background {
        Background(
            scripts: stringArray(dict["scripts"]),
            page: dict["page"] as? String,
            serviceWorker: dict["service_worker"] as? String,
            persistent: dict["persistent"] as? Bool,
            isModule: (dict["type"] as? String) == "module")
    }

    private static func parseAction(_ dict: [String: Any]) -> Action {
        var icon: [String: String] = [:]
        if let single = dict["default_icon"] as? String {
            icon["0"] = single
        } else if let map = dict["default_icon"] as? [String: Any] {
            icon = map.compactMapValues { $0 as? String }
        }
        return Action(defaultTitle: dict["default_title"] as? String,
                      defaultPopup: dict["default_popup"] as? String,
                      defaultIcon: icon)
    }

    /// `declarative_net_request.rule_resources`: [{ id, enabled, path }]. Defaults: enabled=true.
    private static func parseDNRRulesets(_ value: Any?) -> [DNRRuleset] {
        guard let dict = value as? [String: Any],
              let resources = dict["rule_resources"] as? [[String: Any]] else { return [] }
        return resources.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let path = entry["path"] as? String, !path.isEmpty else { return nil }
            return DNRRuleset(id: id, enabled: (entry["enabled"] as? Bool) ?? true, path: path)
        }
    }

    /// `commands`: { name: { suggested_key: {default|...}, description } }. The suggested key may be
    /// a string or a per-platform object; we keep the default (or any) binding for display only.
    private static func parseCommands(_ value: Any?) -> [Command] {
        guard let dict = value as? [String: Any] else { return [] }
        return dict.compactMap { name, raw in
            let body = raw as? [String: Any]
            var key: String?
            if let keyString = body?["suggested_key"] as? String {
                key = keyString
            } else if let keyMap = body?["suggested_key"] as? [String: Any] {
                key = (keyMap["default"] as? String) ?? keyMap.values.compactMap { $0 as? String }.first
            }
            return Command(name: name, suggestedKey: key, description: body?["description"] as? String)
        }
        .sorted { $0.name < $1.name }   // stable order (dictionary iteration is unordered)
    }

    private static func parseWebAccessibleResources(_ value: Any?) -> [WebAccessibleResource] {
        if let strings = value as? [String] {
            // MV2 form: a flat list available to all pages.
            return [WebAccessibleResource(resources: strings, matches: ["<all_urls>"])]
        }
        if let objects = value as? [[String: Any]] {
            // MV3 form: objects with resources + matches.
            return objects.map { entry in
                WebAccessibleResource(resources: stringArray(entry["resources"]),
                                      matches: stringArray(entry["matches"]))
            }
        }
        return []
    }

    // MARK: - Helpers

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func isHostPattern(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://")
    }
}
