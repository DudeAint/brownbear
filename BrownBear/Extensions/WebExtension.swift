//
//  WebExtension.swift
//  BrownBear
//
//  A stored browser extension: a generated id, the raw manifest, install state, and (on disk) its
//  unpacked files. The parsed manifest is derived on demand so the record stays simply Codable.
//

import Foundation

struct WebExtension: Codable, Identifiable, Equatable {

    /// A Chrome-style 32-character extension id (lowercase a–p).
    let id: String
    /// The verbatim manifest.json, re-parsed on demand.
    var manifestJSON: String
    var enabled: Bool
    var installedAt: Date

    init(id: String, manifestJSON: String, enabled: Bool = true, installedAt: Date = Date()) {
        self.id = id
        self.manifestJSON = manifestJSON
        self.enabled = enabled
        self.installedAt = installedAt
    }

    /// The parsed manifest (nil if the stored JSON somehow became invalid).
    var manifest: WebExtensionManifest? {
        guard let data = manifestJSON.data(using: .utf8) else { return nil }
        return try? WebExtensionManifest.parse(data)
    }

    var displayName: String { manifest?.name ?? id }
    var version: String { manifest?.version ?? "—" }

    /// A chrome-extension-style base URL for this extension's resources.
    var baseURLString: String { "chrome-extension://\(id)/" }

    /// Generate a random Chrome-style id (32 chars from a–p, mapping each hex nibble).
    static func generateID() -> String {
        let alphabet = Array("abcdefghijklmnop")
        var result = ""
        for _ in 0..<32 {
            result.append(alphabet[Int.random(in: 0..<16)])
        }
        return result
    }
}
