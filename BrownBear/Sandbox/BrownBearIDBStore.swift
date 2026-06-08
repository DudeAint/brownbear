//
//  BrownBearIDBStore.swift
//  BrownBear
//
//  On-disk persistence for the bundled in-memory IndexedDB engine (brownbear-indexeddb.js) that runs
//  in headless JavaScriptCore contexts. JSC has no IndexedDB, so an extension service worker or a
//  background userscript gets the JS engine plus this snapshot/rehydrate layer: the JS side hands us a
//  full JSON snapshot (debounced), we persist it per-namespace; at boot we read the last snapshot back
//  and the JS side replays it through the public IndexedDB API.
//
//  Security/isolation (CLAUDE.md §5): every namespace — one extension worker, or one userscript — has
//  its OWN snapshot file under Application Support, keyed by the script/extension's stable id, so one
//  context can never read or clobber another's IndexedDB data. Disk writes are serialized on a private
//  queue and written atomically.
//

import Foundation
import JavaScriptCore

/// Persists and rehydrates the headless IndexedDB engine for one isolated namespace at a time.
final class BrownBearIDBStore: @unchecked Sendable {

    static let shared = BrownBearIDBStore()

    /// Which isolated owner a snapshot belongs to. The raw id is the extension's id or the userscript's
    /// UUID string; the subdirectory keeps the two id-spaces from ever colliding.
    enum Namespace {
        case ext(String)
        case script(String)

        var subdirectory: String {
            switch self {
            case .ext: return "ext"
            case .script: return "script"
            }
        }
        var id: String {
            switch self {
            case .ext(let value), .script(let value): return value
            }
        }
    }

    private let queue = DispatchQueue(label: "com.brownbear.idb.store", qos: .utility)
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Install into a JS context

    /// Install the IndexedDB engine + persistence into a headless `JSContext` for `namespace`. MUST be
    /// called on the context's own thread (the JS engine is single-threaded), BEFORE the
    /// extension/userscript source runs so `indexedDB` exists.
    ///
    /// `rehydrate` defaults to true (replay the snapshot here). A caller whose context defines the web
    /// globals a persisted value needs (Blob/File) only AFTER this install — e.g. an extension worker,
    /// whose Blob/File come from the background runtime loaded after the engine — must pass
    /// `rehydrate: false` and call ``rehydrate(into:namespace:)`` once those globals exist, or a
    /// persisted Blob/File would revive as a raw tagged record instead of a real object.
    func install(into context: JSContext, namespace: Namespace, rehydrate shouldRehydrate: Bool = true) {
        // Native sink for snapshots the JS side produces (already debounced in JS); persist off-thread.
        let save: @convention(block) (String) -> Void = { [weak self] json in
            self?.save(json, namespace: namespace)
        }
        context.setObject(save, forKeyedSubscript: "__bb_idb_save" as NSString)

        if let engine = Self.engineSource {
            context.evaluateScript(engine, withSourceURL: URL(string: "brownbear://idb/engine.js"))
        }
        if let persist = Self.persistSource {
            context.evaluateScript(persist, withSourceURL: URL(string: "brownbear://idb/persist.js"))
        }

        if shouldRehydrate { rehydrate(into: context, namespace: namespace) }
    }

    /// Replay the last on-disk snapshot through the public IndexedDB API. Call AFTER the context's web
    /// globals (Blob/File) exist, so a persisted Blob/File revives as a real object rather than a raw
    /// tagged record. The microtask-scheduled engine drains the replay before evaluateScript returns,
    /// so the data is present by the time the extension/userscript source runs. No-op if no snapshot.
    func rehydrate(into context: JSContext?, namespace: Namespace) {
        guard let context else { return }
        guard let snapshot = load(namespace: namespace), !snapshot.isEmpty else { return }
        context.setObject(snapshot, forKeyedSubscript: "__bbIDBInitialSnapshot" as NSString)
        context.evaluateScript("try { __bbIDBRestore(__bbIDBInitialSnapshot); } catch (e) {}")
    }

    /// Force the JS side to snapshot now and persist it — used when a context is shutting down (the
    /// debounced auto-save timer is about to be cancelled, so a recent write would otherwise be lost).
    /// Safe to call even if IndexedDB was never used (the JS guard no-ops).
    func flush(context: JSContext?) {
        context?.evaluateScript("try { if (typeof __bbIDBFlush === 'function') { __bbIDBFlush(); } } catch (e) {}")
    }

    // MARK: - Disk I/O

    /// Hard ceiling on a snapshot we'll read back at boot, so a corrupt/hostile blob can't OOM or block
    /// the launch. Comfortably above any realistic per-namespace store; oversized → fail closed.
    private static let maxSnapshotBytes = 48 * 1024 * 1024

    /// Read the last snapshot for `namespace`, or nil if none was ever written (or it's implausibly
    /// large). Synchronous: callers invoke it during boot on a background thread.
    func load(namespace: Namespace) -> String? {
        let url = fileURL(for: namespace)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > Self.maxSnapshotBytes {
            return nil   // refuse an oversized snapshot rather than materialize it at launch
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Persist a snapshot for `namespace` atomically, off the calling thread.
    func save(_ json: String, namespace: Namespace) {
        queue.async { [self] in
            let url = fileURL(for: namespace)
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try Data(json.utf8).write(to: url, options: .atomic)
            } catch {
                // A failed persist is non-fatal: the in-memory IndexedDB keeps working this session.
            }
        }
    }

    /// Delete a namespace's snapshot (e.g. when its extension/userscript is removed).
    func clear(namespace: Namespace) {
        queue.async { [self] in
            try? fileManager.removeItem(at: fileURL(for: namespace))
        }
    }

    /// Block until all queued writes/clears have completed. The queue is serial, so a sync barrier flushes
    /// everything submitted before it. For tests, so save/clear become deterministic without polling.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Paths + resources

    private func fileURL(for namespace: Namespace) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("BrownBear/idb/\(namespace.subdirectory)", isDirectory: true)
            .appendingPathComponent(sanitized(namespace.id) + ".idb.json")
    }

    /// Keep the on-disk filename to a safe, traversal-free charset (the id is already a UUID/extension
    /// id, but defense-in-depth: a hostile id can never escape the idb directory).
    private func sanitized(_ id: String) -> String {
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

    private static let engineSource: String? = loadResource("brownbear-indexeddb")
    private static let persistSource: String? = loadResource("brownbear-idb-persist")

    private static func loadResource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js")
                ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return source
    }
}
