//
//  BrownBearPageLocalStorageStore.swift
//  BrownBear
//
//  Native-backed persistence for an extension PAGE's window.localStorage. WKWebView gives the
//  chrome-extension:// custom-scheme page origin NO DOM storage, so brownbear-webext-page.js installs a
//  synchronous Storage polyfill — but it was in-memory only, so a popup/options page that keeps its
//  settings in localStorage forgot them the moment it closed ("localStorage reads don't work"). This
//  persists the polyfill's snapshot (a flat string→string map serialized as JSON) per extension, so a
//  page reads its own writes back across reopen and relaunch, exactly as a real browser's localStorage does.
//
//  Security/isolation (CLAUDE.md §5): one snapshot file per extension id under Application Support — page A
//  can never read or clobber page B's localStorage. Writes are serialized on a private queue and written
//  atomically. The snapshot is seeded into the page at document-start as a literal (localStorage is read
//  synchronously, so the data must be present before any page script runs); the page hands back a debounced
//  snapshot on every write through a WKScriptMessageHandler.
//

import Foundation
import WebKit

/// Persists and reads back one extension page's localStorage snapshot. Thread-safe; the disk write is
/// serialized off the calling thread, the read is synchronous (callers seed it at document-start).
final class BrownBearPageLocalStorageStore: @unchecked Sendable {

    static let shared = BrownBearPageLocalStorageStore()

    private let queue = DispatchQueue(label: "com.brownbear.extls.store", qos: .utility)
    private let fileManager = FileManager.default

    private init() {}

    /// Hard ceiling on a snapshot we'll read back to seed a page. A real origin's localStorage is ~5 MB;
    /// allow headroom, but refuse a corrupt/oversized blob rather than bloat the document-start injection.
    private static let maxSnapshotBytes = 10 * 1024 * 1024

    /// The last persisted snapshot (a JSON object string) for `extensionID`, or nil if none was ever
    /// written (or it's implausibly large). Synchronous — seeded into the page at document-start.
    func load(extensionID: String) -> String? {
        let url = fileURL(for: extensionID)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > Self.maxSnapshotBytes {
            return nil   // refuse an oversized snapshot rather than materialize it into the page seed
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Persist a snapshot (the page's serialized localStorage) for `extensionID` atomically, off-thread.
    func save(_ json: String, extensionID: String) {
        queue.async { [self] in
            let url = fileURL(for: extensionID)
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try Data(json.utf8).write(to: url, options: .atomic)
            } catch {
                // A failed persist is non-fatal: the page's in-memory localStorage keeps working this session.
            }
        }
    }

    /// Delete an extension's localStorage snapshot (e.g. when the extension is removed).
    func clear(extensionID: String) {
        queue.async { [self] in
            try? fileManager.removeItem(at: fileURL(for: extensionID))
        }
    }

    /// Block until queued writes/clears complete. The queue is serial, so this flushes everything submitted
    /// before it — used by tests so save/clear become deterministic without polling.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Paths

    private func fileURL(for extensionID: String) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("BrownBear/extls", isDirectory: true)
            .appendingPathComponent(Self.sanitizedFilename(extensionID) + ".ls.json")
    }

    /// Keep the on-disk filename to a safe, traversal-free charset. The id is already a Chrome/Firefox
    /// extension id, but defense-in-depth: a hostile id can never escape the extls directory.
    static func sanitizedFilename(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var out = ""
        out.reserveCapacity(id.count)
        for scalar in id.unicodeScalars {
            if allowed.contains(scalar) || scalar == "-" || scalar == "_" {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "default" : out
    }
}

/// Receives an extension page's debounced localStorage snapshot (`window.__bb_ls_save` → this handler)
/// and persists it under that extension's id. Holds only the id (no view/session reference), so the
/// content controller's strong retention of it can't form a cycle. The store write is thread-safe + off-queue.
@MainActor
final class PageLocalStorageSaveHandler: NSObject, WKScriptMessageHandler {
    private let extensionID: String
    init(extensionID: String) { self.extensionID = extensionID }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String, !json.isEmpty else { return }
        BrownBearPageLocalStorageStore.shared.save(json, extensionID: extensionID)
    }
}
