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

    let id: UUID
    /// The script this line belongs to (nil for engine/system messages).
    let scriptID: UUID?
    let scriptName: String?
    let level: Level
    let message: String
    let createdAt: Date
    let context: Context

    init(id: UUID = UUID(),
         scriptID: UUID?,
         scriptName: String? = nil,
         level: Level = .info,
         message: String,
         createdAt: Date = Date(),
         context: Context = .background) {
        self.id = id
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.level = level
        self.message = message
        self.createdAt = createdAt
        self.context = context
    }
}
