//
//  DownloadManager.swift
//  BrownBear
//
//  Owns file downloads via WKDownloadDelegate — the modern (iOS 14.5+) download API. When the
//  browser decides a navigation response is a file WebKit can't render (a PDF/zip/dmg), it converts
//  it to a WKDownload and hands it here. We pick a destination under Documents/Downloads, observe
//  progress, and publish the list to the Downloads UI.
//
//  Not an actor / not @MainActor: WKDownloadDelegate callbacks arrive on the main thread, so the
//  @Published mutations already happen on main. Progress KVO can fire off-main, so those hops are
//  dispatched to main explicitly. A shared instance is set as the delegate for every download.
//

import Foundation
import WebKit

final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()

    /// Newest first. Drives the Downloads list.
    @Published private(set) var downloads: [DownloadItem] = []

    /// Maps a live WKDownload to the item it's filling, so finish/fail/progress find their row.
    private var idsByDownload: [ObjectIdentifier: UUID] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    private override init() { super.init() }

    /// Attach as the download's delegate. Called from the browser controller when WebKit converts a
    /// navigation into a download. The item itself is created in `decideDestinationUsing` once the
    /// suggested filename is known.
    func begin(_ download: WKDownload) {
        download.delegate = self
    }

    // MARK: - Destination

    /// The app's Documents/Downloads directory, created on demand.
    private func downloadsDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A non-colliding destination: "file.pdf", then "file (1).pdf", "file (2).pdf", …
    private func uniqueDestination(in dir: URL, fileName: String) -> URL {
        let safeName = fileName.isEmpty ? "download" : fileName
        var candidate = dir.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var index = 1
        repeat {
            let name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            candidate = dir.appendingPathComponent(name)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: - Mutations (main thread)

    func remove(id: UUID) {
        progressObservations[id]?.invalidate()
        progressObservations[id] = nil
        if let item = downloads.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: item.localURL)
        }
        downloads.removeAll { $0.id == id }
        idsByDownload = idsByDownload.filter { $0.value != id }
    }

    func clearFinished() {
        for item in downloads where item.isFinished { progressObservations[item.id]?.invalidate() }
        let finishedIDs = Set(downloads.filter(\.isFinished).map(\.id))
        downloads.removeAll { $0.isFinished }
        idsByDownload = idsByDownload.filter { !finishedIDs.contains($0.value) }
    }

    private func updateState(for download: WKDownload, _ apply: (inout DownloadItem) -> Void) {
        guard let id = idsByDownload[ObjectIdentifier(download)],
              let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        apply(&downloads[index])
    }
}

// MARK: - WKDownloadDelegate

extension DownloadManager: WKDownloadDelegate {

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let destination = uniqueDestination(in: downloadsDirectory(), fileName: suggestedFilename)
        let item = DownloadItem(fileName: destination.lastPathComponent, localURL: destination)
        downloads.insert(item, at: 0)
        idsByDownload[ObjectIdentifier(download)] = item.id

        // Observe byte progress; KVO may fire off the main thread, so hop back for @Published.
        progressObservations[item.id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                self?.updateState(for: download) { $0.fractionCompleted = fraction }
            }
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        updateState(for: download) {
            $0.fractionCompleted = 1
            $0.state = .finished
        }
        finishObserving(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        updateState(for: download) { $0.state = .failed(error.localizedDescription) }
        finishObserving(download)
    }

    private func finishObserving(_ download: WKDownload) {
        if let id = idsByDownload[ObjectIdentifier(download)] {
            progressObservations[id]?.invalidate()
            progressObservations[id] = nil
        }
        idsByDownload[ObjectIdentifier(download)] = nil
    }
}
