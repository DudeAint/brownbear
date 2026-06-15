//
//  WebExtensionStore.swift
//  BrownBear
//
//  Installs and manages browser extensions. Installing unpacks a `.crx`/`.zip`, validates its
//  manifest, writes the files to disk under Application Support, and records metadata in an index.
//  An actor: the browser, the chrome.* bridge, and the dashboard all read/write it.
//

import Foundation

actor WebExtensionStore {

    private var extensions: [WebExtension] = []
    private var didLoad = false
    private let baseDirectory: URL
    private let indexURL: URL

    init(baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? ((try? FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("BrownBear/extensions")
        self.baseDirectory = base
        self.indexURL = base.appendingPathComponent("index.json")
    }

    // MARK: - Reads

    func all() -> [WebExtension] {
        loadIfNeeded()
        return extensions
    }

    func enabledExtensions() -> [WebExtension] {
        all().filter(\.enabled)
    }

    func ext(for id: String) -> WebExtension? {
        loadIfNeeded()
        return extensions.first { $0.id == id }
    }

    /// The installed extension that originated from a given Chrome Web Store id, if any. Lets the
    /// in-page store button reflect "already added" and offer Remove.
    func installed(forStoreID storeID: String) -> WebExtension? {
        loadIfNeeded()
        return extensions.first { $0.storeID == storeID }
    }

    /// Read a file packaged inside an extension (e.g. a content script or resource). Both the
    /// extension id and the path are contained: the id is the `chrome-extension://` host, which
    /// arrives from untrusted page navigations, so a host like `..` must not relocate the
    /// containment root above this extension's directory; and a `..` path must not let one
    /// extension read another's on-disk source.
    func file(extensionID: String, path: String) -> Data? {
        // Reject anything that isn't a well-formed Chrome id (a `..`/`../../x` host would otherwise
        // standardize the root up and out of the extensions directory before the anchor is taken).
        guard ChromeWebStore.isExtensionID(extensionID) else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let root = directory(for: extensionID).standardizedFileURL
        let url = root.appendingPathComponent(cleaned).standardizedFileURL
        // Contain within this extension's directory AND within the extensions base directory.
        let baseRoot = baseDirectory.standardizedFileURL.path
        guard url.path == root.path || url.path.hasPrefix(root.path + "/"),
              url.path.hasPrefix(baseRoot + "/") else { return nil }
        return try? Data(contentsOf: url)
    }

    func text(extensionID: String, path: String) -> String? {
        file(extensionID: extensionID, path: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Synchronous, non-isolated packaged-file read with the same containment guarantees as `file`.
    /// `baseDirectory` is an immutable `let` of a `Sendable` type, so reading it off-actor is race-free,
    /// and the on-disk files are immutable for the life of an install. Exists so synchronous UI code —
    /// `WebExtension.displayName`/`displayDescription` resolving `__MSG_*__` placeholders — can read the
    /// default-locale messages.json without an `await` it cannot perform. Do NOT use it for anything the
    /// actor mutates (the index); it only touches the immutable package tree.
    nonisolated func fileSync(extensionID: String, path: String) -> Data? {
        guard ChromeWebStore.isExtensionID(extensionID) else { return nil }
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let root = baseDirectory.appendingPathComponent(extensionID, isDirectory: true).standardizedFileURL
        let url = root.appendingPathComponent(cleaned).standardizedFileURL
        let baseRoot = baseDirectory.standardizedFileURL.path
        guard url.path == root.path || url.path.hasPrefix(root.path + "/"),
              url.path.hasPrefix(baseRoot + "/") else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Install / manage

    /// Install an extension from a `.crx`/`.zip` package. Returns the stored record. `storeID` is the
    /// Chrome Web Store id it came from (when installed via the store), recorded so the in-page store
    /// button can detect "already added"; pass `nil` for a sideloaded archive.
    @discardableResult
    func install(archive: Data, storeID: String? = nil) async throws -> WebExtension {
        loadIfNeeded()
        let files = try WebExtensionArchive.unpack(archive)
        guard let manifestData = files["manifest.json"] else {
            throw BrownBearError.metadataParseFailed("the package has no manifest.json")
        }
        // Validate the manifest before committing anything to disk.
        _ = try WebExtensionManifest.parse(manifestData)
        let manifestJSON = String(decoding: manifestData, as: UTF8.self)

        // Re-installing from the same store page replaces the prior copy rather than duplicating it.
        if let storeID, let existing = extensions.first(where: { $0.storeID == storeID }) {
            try? FileManager.default.removeItem(at: directory(for: existing.id))
            extensions.removeAll { $0.id == existing.id }
        }

        let id = WebExtension.generateID()
        try writeFiles(files, for: id)

        let record = WebExtension(id: id, manifestJSON: manifestJSON, storeID: storeID)
        extensions.append(record)
        persist()
        return record
    }

    func setEnabled(id: String, _ enabled: Bool) {
        loadIfNeeded()
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[index].enabled = enabled
        persist()
    }

    func remove(id: String) {
        loadIfNeeded()
        extensions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory(for: id))
        BrownBearIDBStore.shared.clear(namespace: .ext(id))   // drop its headless IndexedDB snapshot too
        BrownBearPageLocalStorageStore.shared.clear(extensionID: id)   // and its pages' persisted localStorage
        persist()
    }

    // MARK: - Disk

    private func directory(for id: String) -> URL {
        baseDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private func writeFiles(_ files: [String: Data], for id: String) throws {
        let root = directory(for: id)
        for (path, contents) in files {
            let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !cleaned.isEmpty, !cleaned.contains("..") else { continue } // ignore path traversal
            let fileURL = root.appendingPathComponent(cleaned)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: fileURL, options: .atomic)
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.brownBear.decode([WebExtension].self, from: data) else { return }
        extensions = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.brownBear.encode(extensions)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Best-effort; the in-memory set stays authoritative for this session.
        }
    }
}
