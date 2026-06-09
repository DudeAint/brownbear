//
//  WebExtensionDownloadsManager.swift
//  BrownBear
//
//  chrome.downloads — the native side. A worker calls chrome.downloads.download({url, …}); we run the
//  transfer with a URLSession download task into the app's Downloads directory, surface it in the
//  Downloads UI (via DownloadManager), and fire onCreated/onChanged into the OWNING extension's worker
//  (through the runtime). Chrome download ids are integers, so we mint our own; the chrome DownloadItem
//  shape is assembled from our per-download record. The "downloads" permission gate is enforced by the
//  native before any method reaches here.
//
//  @MainActor: the record store + DownloadManager mirror are main-actor state; URLSession's completion /
//  progress callbacks arrive off-main and hop back here.
//

import Foundation

@MainActor
final class WebExtensionDownloadsManager {

    /// One chrome download. The source of truth for the chrome DownloadItem shape; `uuid` links it to
    /// the DownloadManager row shown in the Downloads UI.
    private final class Record {
        let id: Int
        let uuid: UUID
        let extensionID: String
        let url: String
        var filename: String           // absolute local path
        var mime: String
        var state: String              // "in_progress" | "complete" | "interrupted"
        var paused: Bool
        var canResume: Bool
        var error: String?
        var bytesReceived: Int64
        var totalBytes: Int64
        let startTime: Date
        var endTime: Date?
        var task: URLSessionDownloadTask?
        var session: URLSession?               // per-download guarded session; invalidated on finish
        var progressObservation: NSKeyValueObservation?

        init(id: Int, uuid: UUID, extensionID: String, url: String, filename: String) {
            self.id = id; self.uuid = uuid; self.extensionID = extensionID; self.url = url
            self.filename = filename; self.mime = "application/octet-stream"; self.state = "in_progress"
            self.paused = false; self.canResume = false; self.error = nil
            self.bytesReceived = 0; self.totalBytes = -1; self.startTime = Date(); self.endTime = nil
        }
    }

    private var records: [Int: Record] = [:]
    private var counter = 0

    // MARK: - download

    /// chrome.downloads.download. Returns ["downloadId": Int] on success, or ["error": msg].
    func download(extensionID: String, options: [String: Any]) -> [String: Any] {
        guard let urlString = options["url"] as? String, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return ["error": "Invalid or unsupported download URL."]
        }
        // Fail closed on SSRF targets — a download must not reach loopback/private/link-local hosts
        // (CLAUDE.md §5). The redirect guard below re-checks every 3xx target too.
        guard !WebExtensionFetchSecurity.isBlockedHost(url.host) else {
            return ["error": "Refusing to download from a private or loopback address."]
        }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String)?.uppercased() == "POST" ? "POST" : "GET"
        if let headers = options["headers"] as? [[String: Any]] {
            // chrome passes headers as [{name, value}]. Drop CR/LF/NUL-bearing values + non-token names.
            for header in headers {
                guard let name = header["name"] as? String, let value = header["value"] as? String,
                      Self.isSafeHeader(name: name, value: value) else { continue }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if request.httpMethod == "POST", let body = options["body"] as? String {
            request.httpBody = Data(body.utf8)
        }

        let suggested = Self.sanitizedFilename((options["filename"] as? String) ?? url.lastPathComponent,
                                               fallback: url.host ?? "download")
        let destination = DownloadManager.shared.extensionDownloadDestination(suggestedName: suggested)

        counter += 1
        let id = counter
        let uuid = UUID()
        let record = Record(id: id, uuid: uuid, extensionID: extensionID, url: urlString,
                            filename: destination.path)
        DownloadManager.shared.insertExtensionDownload(
            DownloadItem(id: uuid, fileName: destination.lastPathComponent, localURL: destination))

        let session = WebExtensionFetchSecurity.downloadGuardedSession()
        record.session = session
        let task = session.downloadTask(with: request) { [weak self] temp, response, error in
            // temp/response/error are value-or-Sendable; capture the result, hop to the main actor.
            let movedOK: Bool
            var finalPath = destination.path
            var failure: String?
            var mime = "application/octet-stream"
            if let temp, error == nil {
                if let mt = response?.mimeType { mime = mt }
                // Re-uniquify at completion (the path was only RESERVED at start; a concurrent same-name
                // download may have landed there) — never blind-overwrite an existing file.
                let target = FileManager.default.fileExists(atPath: destination.path)
                    ? destination.deletingLastPathComponent().appendingPathComponent(
                        "\(UUID().uuidString)-\(destination.lastPathComponent)")
                    : destination
                do {
                    try FileManager.default.moveItem(at: temp, to: target)
                    finalPath = target.path
                    movedOK = true
                } catch { movedOK = false; failure = error.localizedDescription }
            } else {
                movedOK = false
                failure = error?.localizedDescription ?? "download failed"
            }
            let finalMime = mime
            let pathResult = finalPath
            let okResult = movedOK
            let failResult = failure
            Task { @MainActor [weak self] in
                self?.finish(id: id, succeeded: okResult, error: failResult, mime: finalMime, finalPath: pathResult)
            }
        }
        record.task = task
        record.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                self?.updateProgress(id: id, fraction: fraction, received: received, total: total)
            }
        }
        records[id] = record
        task.resume()
        fireEvent(extensionID: extensionID, kind: "onCreated", payload: chromeItem(record))
        return ["downloadId": id]
    }

    private func updateProgress(id: Int, fraction: Double, received: Int64, total: Int64) {
        guard let record = records[id], record.state == "in_progress" else { return }
        record.bytesReceived = received
        record.totalBytes = total > 0 ? total : record.totalBytes
        DownloadManager.shared.updateExtensionDownload(id: record.uuid) {
            $0.fractionCompleted = max(0, min(1, fraction))
        }
        fireEvent(extensionID: record.extensionID, kind: "onChanged",
                  payload: ["id": id, "bytesReceived": ["current": received]])
    }

    private func finish(id: Int, succeeded: Bool, error: String?, mime: String, finalPath: String? = nil) {
        // Idempotent: only an in-progress download settles. cancel() calls this directly AND the task's
        // cancellation later fires the completion handler → finish() again; the second is a no-op.
        guard let record = records[id], record.state == "in_progress" else { return }
        record.progressObservation?.invalidate()
        record.progressObservation = nil
        record.task = nil
        record.session?.finishTasksAndInvalidate()
        record.session = nil
        record.endTime = Date()
        record.mime = mime
        let previous = record.state
        if succeeded {
            record.state = "complete"
            if let finalPath { record.filename = finalPath }
            record.bytesReceived = record.totalBytes > 0 ? record.totalBytes : record.bytesReceived
            let finalURL = URL(fileURLWithPath: record.filename)
            DownloadManager.shared.updateExtensionDownload(id: record.uuid) {
                $0.state = .finished; $0.fractionCompleted = 1; $0.localURL = finalURL
                $0.fileName = finalURL.lastPathComponent
            }
        } else {
            record.state = "interrupted"
            record.error = error ?? "INTERRUPTED"
            DownloadManager.shared.updateExtensionDownload(id: record.uuid) {
                $0.state = .failed(error ?? "failed")
            }
        }
        var delta: [String: Any] = ["id": id, "state": ["previous": previous, "current": record.state]]
        if let err = record.error { delta["error"] = ["current": err] }
        fireEvent(extensionID: record.extensionID, kind: "onChanged", payload: delta)
    }

    // MARK: - search / control

    /// chrome.downloads.search — the extension's downloads matching `query` (id and state filters; an
    /// empty query returns all). Newest first.
    func search(extensionID: String, query: [String: Any]) -> [[String: Any]] {
        var matches = records.values.filter { $0.extensionID == extensionID }
        if let wantID = query["id"] as? Int { matches = matches.filter { $0.id == wantID } }
        if let state = query["state"] as? String { matches = matches.filter { $0.state == state } }
        if let paused = query["paused"] as? Bool { matches = matches.filter { $0.paused == paused } }
        let sorted = matches.sorted { $0.startTime > $1.startTime }
        let limited = (query["limit"] as? Int).map { Array(sorted.prefix(max(0, $0))) } ?? sorted
        return limited.map { chromeItem($0) }
    }

    /// chrome.downloads.cancel — abort an in-progress download. finish() is idempotent, so the task's
    /// later cancellation callback is a no-op.
    func cancel(extensionID: String, id: Int) -> Bool {
        guard let record = records[id], record.extensionID == extensionID, record.state == "in_progress" else { return false }
        record.task?.cancel()
        finish(id: id, succeeded: false, error: "USER_CANCELED", mime: record.mime)
        return true
    }

    /// chrome.downloads.pause — suspend a live transfer. `canResume` is true only while paused (we don't
    /// hold resumeData for a real interrupt — resume only un-pauses a still-suspended task).
    func pause(extensionID: String, id: Int) -> Bool {
        guard let record = records[id], record.extensionID == extensionID,
              record.state == "in_progress", !record.paused else { return false }
        record.paused = true
        record.canResume = true
        record.task?.suspend()
        fireEvent(extensionID: extensionID, kind: "onChanged",
                  payload: ["id": id, "paused": ["previous": false, "current": true]])
        return true
    }

    func resume(extensionID: String, id: Int) -> Bool {
        guard let record = records[id], record.extensionID == extensionID,
              record.paused, record.state == "in_progress" else { return false }
        record.paused = false
        record.canResume = false
        record.task?.resume()
        fireEvent(extensionID: extensionID, kind: "onChanged",
                  payload: ["id": id, "paused": ["previous": true, "current": false]])
        return true
    }

    /// chrome.downloads.erase — remove matching records (does NOT delete files); returns erased ids. An
    /// in-flight download being erased has its task cancelled and its Downloads-UI row dropped so it
    /// doesn't linger at "downloading…" forever.
    func erase(extensionID: String, query: [String: Any]) -> [Int] {
        let toErase = search(extensionID: extensionID, query: query).compactMap { $0["id"] as? Int }
        for id in toErase {
            if let record = records[id] {
                record.task?.cancel()
                record.progressObservation?.invalidate()
                record.session?.finishTasksAndInvalidate()
                if record.state == "in_progress" { DownloadManager.shared.remove(id: record.uuid) }
            }
            records.removeValue(forKey: id)
            fireEvent(extensionID: extensionID, kind: "onErased", payload: id)
        }
        return toErase
    }

    /// chrome.downloads.removeFile — delete the downloaded file (record stays, exists:false).
    func removeFile(extensionID: String, id: Int) -> Bool {
        guard let record = records[id], record.extensionID == extensionID, record.state == "complete" else { return false }
        try? FileManager.default.removeItem(atPath: record.filename)
        DownloadManager.shared.updateExtensionDownload(id: record.uuid) { _ in }   // row stays
        return true
    }

    /// Drop an extension's downloads when it's unloaded: cancel in-flight tasks and settle their
    /// Downloads-UI rows to failed (so they don't sit at "downloading…" forever).
    func close(extensionID: String) {
        for record in records.values where record.extensionID == extensionID {
            if record.state == "in_progress" {
                record.task?.cancel()
                record.progressObservation?.invalidate()
                record.session?.finishTasksAndInvalidate()
                DownloadManager.shared.updateExtensionDownload(id: record.uuid) {
                    $0.state = .failed("interrupted")
                }
            }
            records.removeValue(forKey: record.id)
        }
    }

    // MARK: - Shape + helpers

    private func chromeItem(_ r: Record) -> [String: Any] {
        var item: [String: Any] = [
            "id": r.id, "url": r.url, "finalUrl": r.url, "referrer": "",
            "filename": r.filename, "incognito": false, "danger": "safe", "mime": r.mime,
            "startTime": Self.iso8601(r.startTime), "estimatedEndTime": NSNull(),
            "state": r.state, "paused": r.paused, "canResume": r.canResume,
            "bytesReceived": r.bytesReceived, "totalBytes": r.totalBytes,
            "fileSize": r.totalBytes, "exists": r.state == "complete",
            "byExtensionId": r.extensionID
        ]
        item["endTime"] = r.endTime.map { Self.iso8601($0) } ?? NSNull()
        if let error = r.error { item["error"] = error }
        return item
    }

    private func fireEvent(extensionID: String, kind: String, payload: Any) {
        BrownBearServices.shared.webExtensionRuntime.fireDownloadEvent(
            extensionID: extensionID, kind: kind, payload: payload)
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// A safe filename: last path component only (no traversal), trimmed, non-empty.
    /// `nonisolated` (pure) + internal so it's unit-tested directly.
    nonisolated static func sanitizedFilename(_ raw: String, fallback: String) -> String {
        let base = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\u{0}", with: "")
        if !cleaned.isEmpty && cleaned != "." && cleaned != ".." { return cleaned }
        let fb = (fallback as NSString).lastPathComponent
        return fb.isEmpty ? "download" : fb
    }

    /// Reject header names that aren't tokens and values bearing CR/LF/NUL (header injection), plus the
    /// handful URLSession must own. `nonisolated` (pure) + internal so it's unit-tested directly.
    nonisolated static func isSafeHeader(name: String, value: String) -> Bool {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && !"()<>@,;:\\\"/[]?={} \t".unicodeScalars.contains($0) }),
              !value.unicodeScalars.contains(where: { $0.value == 0x0D || $0.value == 0x0A || $0.value == 0x00 }) else {
            return false
        }
        let forbidden: Set<String> = ["host", "content-length", "connection", "proxy-connection",
                                      "transfer-encoding", "upgrade"]
        return !forbidden.contains(name.lowercased())
    }
}
