//
//  UserScript.swift
//  BrownBear
//
//  A stored userscript: its full source plus the parsed metadata and management state. This is
//  the durable record the dashboard lists, the engine matches, and the sandbox executes. Named
//  `UserScript` (not `Script`) to read clearly alongside WebKit's `WKUserScript`.
//

import Foundation

/// Per-script user overrides layered on top of the script's own `@metadata`. This is the
/// Tampermonkey/ScriptCat "script settings" surface: the user can retime injection, force an
/// execution context, or exclude one script from auto-update **without editing its source**.
///
/// Every field is optional and `nil` means "defer to what the script declares (or the global
/// default)". The struct is pruned back to `nil` on the owning `UserScript` when empty (see
/// `isEmpty`), so untouched scripts stay byte-identical in storage and old records decode cleanly.
struct ScriptOverrides: Codable, Equatable {
    /// Overrides `@run-at`. `nil` honors the script's declared injection timing.
    var runAt: RunAt?
    /// Overrides `@inject-into` (execution context). `nil` honors the declared context.
    var injectInto: InjectInto?
    /// Per-script auto-update control. `nil` follows the global `AppSettings.autoUpdateScripts`;
    /// `true`/`false` force-enable or force-exclude this one script from the automatic pass.
    var autoUpdate: Bool?

    /// True when no override is set — used to prune the field back to `nil` on persist.
    var isEmpty: Bool { runAt == nil && injectInto == nil && autoUpdate == nil }
}

struct UserScript: Codable, Identifiable, Equatable {

    let id: UUID
    /// The complete script text, including the metadata block.
    var source: String
    /// Parsed metadata, cached so we don't re-parse on every navigation.
    var metadata: ScriptMetadata
    /// Whether the script is allowed to run.
    var enabled: Bool
    /// User overrides layered over the parsed metadata (injection timing/context, auto-update).
    /// `nil` (the common case) means every setting follows the script's own directives.
    var overrides: ScriptOverrides?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         source: String,
         metadata: ScriptMetadata,
         enabled: Bool = true,
         overrides: ScriptOverrides? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.source = source
        self.metadata = metadata
        self.enabled = enabled
        self.overrides = overrides
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The injection timing actually used: a user override if set, else the script's `@run-at`.
    var effectiveRunAt: RunAt { overrides?.runAt ?? metadata.runAt }

    /// The execution context actually used: a user override if set, else the script's `@inject-into`.
    var effectiveInjectInto: InjectInto { overrides?.injectInto ?? metadata.injectInto }

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
