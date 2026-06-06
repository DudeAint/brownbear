//
//  BrownBearError.swift
//  BrownBear
//
//  The app's typed error domain. Per CLAUDE.md we never throw ad-hoc NSErrors; every failure
//  is a case here with a user-presentable description.
//

import Foundation

/// All recoverable errors surfaced by BrownBear's own code.
enum BrownBearError: LocalizedError, Equatable {
    /// The omnibox input could not be turned into a navigable URL or search.
    case invalidOmniboxInput(String)
    /// A tab was requested that no longer exists.
    case unknownTab(UUID)
    /// Navigation failed with an underlying message from WebKit.
    case navigationFailed(String)
    /// A userscript's metadata block was missing or invalid.
    case metadataParseFailed(String)
    /// A GM bridge request was malformed or violated a script's grants/connect allowlist.
    case bridgeRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidOmniboxInput(let text):
            return "“\(text)” isn’t a valid address or search."
        case .unknownTab(let id):
            return "That tab is no longer open (\(id.uuidString.prefix(8)))."
        case .navigationFailed(let message):
            return "Couldn’t load the page: \(message)"
        case .metadataParseFailed(let reason):
            return "Couldn’t read the userscript: \(reason)"
        case .bridgeRejected(let reason):
            return "Script request rejected: \(reason)"
        }
    }
}
