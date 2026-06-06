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

    /// Read a file packaged inside an extension (e.g. a content script or resource). Paths come
    /// from the extension's own manifest, so we contain them to this extension's directory — a
    /// `..` path must not let one extension read another's on-disk source.
    func file(extensionID: String, path: String) -> Data? {
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let root = directory(for: extensionID).standardizedFileURL
        let url = root.appendingPathComponent(cleaned).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        return try? Data(contentsOf: url)
    }

    func text(extensionID: String, path: String) -> String? {
        file(extensionID: extensionID, path: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Install / manage

    /// Install an extension from a `.crx`/`.zip` package. Returns the stored record.
    @discardableResult
    func install(archive: Data) async throws -> WebExtension {
        loadIfNeeded()
        let files = try WebExtensionArchive.unpack(archive)
        guard let manifestData = files["manifest.json"] else {
            throw BrownBearError.metadataParseFailed("the package has no manifest.json")
        }
        // Validate the manifest before committing anything to disk.
        _ = try WebExtensionManifest.parse(manifestData)
        let manifestJSON = String(decoding: manifestData, as: UTF8.self)

        let id = WebExtension.generateID()
        try writeFiles(files, for: id)

        let record = WebExtension(id: id, manifestJSON: manifestJSON)
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
