//
//  LogEntry.swift
//  BrownBear
//
//  One line of execution output — from GM_log, console.*, a background run's result, or an
//  error. The dashboard (Module 5) renders these; the scheduler writes them. Secrets must be
//  scrubbed by callers before logging (CLAUDE.md §5.5).
//

import Foundation

struct LogEntry: Codable, Identifiable, Equatable {

    enum Level: String, Codable { case debug, info, warn, error }
    enum Context: String, Codable { case foreground, background }

    /// Where the line originated: `userscript` (GM_log/console from the isolated world), `page` or
    /// `iframe` (the page's own console.*, captured per-frame), or `engine` (system/extension).
    enum Source: String, Codable { case userscript, page, iframe, engine }

    let id: UUID
    /// The script this line belongs to (nil for engine/system messages).
    let scriptID: UUID?
    let scriptName: String?
    let level: Level
    let message: String
    let createdAt: Date
    let context: Context
    let source: Source

    init(id: UUID = UUID(),
         scriptID: UUID?,
         scriptName: String? = nil,
         level: Level = .info,
         message: String,
         createdAt: Date = Date(),
         context: Context = .background,
         source: Source = .userscript) {
        self.id = id
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.level = level
        self.message = message
        self.createdAt = createdAt
        self.context = context
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, scriptID, scriptName, level, message, createdAt, context, source
    }

    /// Custom decode so entries persisted before `source` existed still load (defaulting to
    /// `.userscript`, what those legacy lines were) instead of throwing and wiping the log history.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        scriptID = try container.decodeIfPresent(UUID.self, forKey: .scriptID)
        scriptName = try container.decodeIfPresent(String.self, forKey: .scriptName)
        level = try container.decode(Level.self, forKey: .level)
        message = try container.decode(String.self, forKey: .message)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        context = try container.decode(Context.self, forKey: .context)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .userscript
    }
}
