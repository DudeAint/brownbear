//
//  DownloadItem.swift
//  BrownBear
//
//  One in-progress or finished file download. A value type the DownloadManager publishes to the
//  Downloads UI. Files land in the app's Documents/Downloads so the user can open/share them.
//

import Foundation

struct DownloadItem: Identifiable, Equatable {

    enum State: Equatable {
        case downloading
        case finished
        case failed(String)
    }

    let id: UUID
    var fileName: String
    var localURL: URL
    var state: State
    var fractionCompleted: Double
    let startedAt: Date

    init(id: UUID = UUID(),
         fileName: String,
         localURL: URL,
         state: State = .downloading,
         fractionCompleted: Double = 0,
         startedAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.localURL = localURL
        self.state = state
        self.fractionCompleted = fractionCompleted
        self.startedAt = startedAt
    }

    var isFinished: Bool { state == .finished }

    /// Human label for the current state.
    var statusText: String {
        switch state {
        case .downloading: return "\(Int(fractionCompleted * 100))%"
        case .finished: return "Done"
        case .failed(let message): return "Failed — \(message)"
        }
    }
}
