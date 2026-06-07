//
//  FirefoxAddons.swift
//  BrownBear
//
//  Direct install from Mozilla Add-ons (AMO). Firefox extensions are XPI files — which are just ZIPs
//  with a manifest.json — so `WebExtensionArchive` unpacks them with no special handling and they run
//  on the same chrome.*/browser.* surface (Firefox extensions use the Promise-based `browser.*`, which
//  BrownBear already aliases to `chrome`). The current XPI URL is resolved via AMO's public API.
//

import Foundation

enum FirefoxAddons {

    /// The add-on slug from an AMO URL (addons.mozilla.org/<locale?>/firefox/addon/<slug>/) or a bare
    /// slug typed directly.
    static func slug(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), (url.host?.lowercased().hasSuffix("addons.mozilla.org") == true) {
            let components = url.pathComponents
            if let index = components.firstIndex(of: "addon"), index + 1 < components.count {
                let slug = components[index + 1]
                return slug.isEmpty ? nil : slug
            }
            return nil
        }
        // A bare slug (no scheme, single path-less token).
        if !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" "), !trimmed.contains(".") {
            return trimmed
        }
        return nil
    }

    /// Resolve the current XPI download URL + display name from AMO's API.
    static func resolve(slug: String, session: URLSession = .shared) async throws -> (url: URL, name: String) {
        guard let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/") else {
            throw BrownBearError.metadataParseFailed("that doesn't look like a Firefox add-on")
        }
        let (data, response) = try await session.data(from: api)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BrownBearError.navigationFailed("AMO returned HTTP \(http.statusCode) for \(slug)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["current_version"] as? [String: Any] else {
            throw BrownBearError.metadataParseFailed("couldn't read the Firefox add-on metadata")
        }
        // v5 nests the package under `file`; older shapes used a `files` array.
        let fileURLString = (version["file"] as? [String: Any])?["url"] as? String
            ?? (version["files"] as? [[String: Any]])?.first?["url"] as? String
        guard let fileURLString, let fileURL = URL(string: fileURLString) else {
            throw BrownBearError.metadataParseFailed("the Firefox add-on has no downloadable file")
        }
        let name = (json["name"] as? [String: Any])?["en-US"] as? String
            ?? (json["name"] as? String) ?? slug
        return (fileURL, name)
    }

    /// Download the XPI (ZIP) bytes for a Firefox add-on slug.
    static func downloadXPI(slug: String, session: URLSession = .shared) async throws -> Data {
        let resolved = try await resolve(slug: slug, session: session)
        let (data, response) = try await session.data(from: resolved.url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BrownBearError.navigationFailed("the Firefox add-on download returned HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw BrownBearError.metadataParseFailed("the Firefox add-on package was empty")
        }
        return data
    }
}
