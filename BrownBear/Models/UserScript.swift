//
//  UserScript.swift
//  BrownBear
//
//  A stored userscript: its full source plus the parsed metadata and management state. This is
//  the durable record the dashboard lists, the engine matches, and the sandbox executes. Named
//  `UserScript` (not `Script`) to read clearly alongside WebKit's `WKUserScript`.
//

import Foundation

struct UserScript: Codable, Identifiable, Equatable {

    let id: UUID
    /// The complete script text, including the metadata block.
    var source: String
    /// Parsed metadata, cached so we don't re-parse on every navigation.
    var metadata: ScriptMetadata
    /// Whether the script is allowed to run.
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         source: String,
         metadata: ScriptMetadata,
         enabled: Bool = true,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.metadata = metadata
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Build a script from raw source, parsing (and validating) its metadata.
    /// - Throws: `BrownBearError.metadataParseFailed` if the header is missing/invalid.
    static func make(from source: String,
                     id: UUID = UUID(),
                     enabled: Bool = true,
                     parser: ScriptMetadataParser = ScriptMetadataParser()) throws -> UserScript {
        let metadata = try parser.parse(source)
        let now = Date()
        return UserScript(id: id, source: source, metadata: metadata,
                          enabled: enabled, createdAt: now, updatedAt: now)
    }

    /// Re-parse `source` and update metadata + `updatedAt` in place.
    /// - Throws: `BrownBearError.metadataParseFailed` if the new source is invalid.
    mutating func updateSource(_ newSource: String,
                               parser: ScriptMetadataParser = ScriptMetadataParser()) throws {
        let metadata = try parser.parse(newSource)
        self.source = newSource
        self.metadata = metadata
        self.updatedAt = Date()
    }

    var displayName: String { metadata.displayName }

    /// The body executed in the sandbox: the full source. (The metadata block is comments, so
    /// it is harmless to include and keeps line numbers aligned for error reporting.)
    var executableBody: String { source }
}
