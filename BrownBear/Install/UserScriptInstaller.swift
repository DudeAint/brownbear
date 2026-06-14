//
//  UserScriptInstaller.swift
//  BrownBear
//
//  Fetches and installs userscripts from a URL — the shared engine behind both the dashboard's
//  "Import from URL" and the browser's one-tap `*.user.js` install. Fetching is a plain GET (or a
//  local file read); installation goes through `ScriptStore` so the metadata block is parsed and
//  validated exactly like a hand-written script. We never execute fetched code — we parse it, show
//  the user what it declares (matches, grants), and only install on explicit confirmation.
//

import Foundation

@MainActor
final class UserScriptInstaller {

    static let shared = UserScriptInstaller()

    private let scriptStore: ScriptStore
    private let session: URLSession
    private let parser = ScriptMetadataParser()

    /// A defensive cap on fetched source. Real userscripts are far smaller; this just stops a
    /// hostile URL from streaming us into a memory spike.
    static let maxSourceBytes = 5 * 1024 * 1024

    init(scriptStore: ScriptStore = BrownBearServices.shared.scriptStore,
         session: URLSession = .shared) {
        self.scriptStore = scriptStore
        self.session = session
    }

    /// The conventional userscript URL suffix Greasemonkey/Tampermonkey/Violentmonkey all use, and
    /// the trigger for the browser's auto-install prompt. `nonisolated` (pure, no actor state) so the
    /// browser's nav delegate and tests can call it without hopping to the main actor.
    nonisolated static func isUserScriptURL(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".user.js")
    }

    /// Everything the install sheet needs to show before the user commits.
    struct Preview: Equatable {
        var source: String
        var sourceURL: URL?
        var metadata: ScriptMetadata
        /// If set, an already-installed script (same @name + @namespace) this install would replace.
        var existingID: UUID?
        var existingVersion: String?

        var isUpdate: Bool { existingID != nil }
        var byteCount: Int { source.utf8.count }
        var lineCount: Int { source.reduce(into: 1) { count, character in if character == "\n" { count += 1 } } }
        /// A script with no @match/@include never runs on any page — worth warning about.
        var runsOnNoPages: Bool { metadata.matches.isEmpty && metadata.includes.isEmpty && !metadata.runsInBackground }
    }

    // MARK: - Fetch

    /// Download (or read) the raw source for a userscript URL. http/https/file only.
    func fetchSource(from url: URL) async throws -> String {
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            return try decode(data)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw BrownBearError.metadataParseFailed("only http(s) and file URLs can be imported")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/plain, application/javascript;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BrownBearError.navigationFailed("the server returned HTTP \(http.statusCode)")
        }
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> String {
        guard data.count <= Self.maxSourceBytes else {
            throw BrownBearError.metadataParseFailed("the script is too large (over \(Self.maxSourceBytes / (1024 * 1024)) MB)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrownBearError.metadataParseFailed("the script isn't UTF-8 text")
        }
        return text
    }

    // MARK: - Preview

    /// Parse raw source into a preview, detecting an existing script this would update.
    func makePreview(source: String, url: URL?) async throws -> Preview {
        let metadata = try parser.parse(source)
        let existing = await findExisting(name: metadata.name, namespace: metadata.namespace)
        return Preview(source: source,
                       sourceURL: url,
                       metadata: metadata,
                       existingID: existing?.id,
                       existingVersion: existing?.metadata.version)
    }

    /// Fetch and parse in one step.
    func preview(url: URL) async throws -> Preview {
        let source = try await fetchSource(from: url)
        return try await makePreview(source: source, url: url)
    }

    // MARK: - Install

    /// Commit a preview: replace the matching installed script in place, or add a new one.
    @discardableResult
    func install(_ preview: Preview) async throws -> UserScript {
        let installed: UserScript
        if let existingID = preview.existingID {
            installed = try await scriptStore.updateSource(id: existingID, source: preview.source)
        } else {
            installed = try await scriptStore.add(source: preview.source)
        }
        // Warm the @require/@resource cache in the background so the FIRST page load already has the
        // script's dependencies ready (and offline-safe) — Violentmonkey fetches @require at install.
        // Best-effort and detached: a slow/failed download never blocks or fails the install; the
        // runtime's normal fetch (which also warms the cache) is the fallback.
        Self.prefetchAssets(for: installed.metadata)
        return installed
    }

    /// Kick off a non-blocking warm-up of every declared @require/@resource into GMAssetCache, so a
    /// freshly installed/updated script's dependencies are cached before its first matching navigation.
    nonisolated static func prefetchAssets(for metadata: ScriptMetadata) {
        let urls = assetURLs(for: metadata)
        guard !urls.isEmpty else { return }
        let connects = metadata.connects
        Task.detached(priority: .utility) {
            for string in urls {
                guard let url = URL(string: string) else { continue }
                _ = try? await ScriptMessageRouter.fetchAndCacheAsset(url, connects: connects)
            }
        }
    }

    /// Every asset URL to warm for a script: its @require URLs plus its @resource target URLs, de-duped
    /// (a URL listed as both is fetched once). Pure (nonisolated, no IO) so it is unit-tested directly.
    nonisolated static func assetURLs(for metadata: ScriptMetadata) -> Set<String> {
        var urls = Set(metadata.requires)
        urls.formUnion(metadata.resources.values)
        return urls
    }

    /// An installed script with the same identity (@name + @namespace). Matching on both mirrors
    /// how Tampermonkey decides "install" vs "update".
    private func findExisting(name: String, namespace: String?) async -> UserScript? {
        guard !name.isEmpty else { return nil }
        let all = await scriptStore.all()
        return all.first { $0.metadata.name == name && $0.metadata.namespace == namespace }
    }
}
