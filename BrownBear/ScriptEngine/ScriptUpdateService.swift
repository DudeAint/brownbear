//
//  ScriptUpdateService.swift
//  BrownBear
//
//  Checks installed userscripts for a newer @version at their @downloadURL/@updateURL and re-installs
//  those that have one (the Tampermonkey/ScriptCat update loop). User-gated by AppSettings
//  .autoUpdateScripts; also invocable manually. Network uses an ephemeral session; a script with no
//  update/download URL (e.g. pasted source) is simply skipped.
//

import Foundation

final class ScriptUpdateService {

    /// Outcome of a single manual update check, for user-facing feedback.
    enum UpdateOutcome: Equatable {
        /// Re-installed; the associated value is the new @version string.
        case updated(String)
        /// The remote @version is not newer than the installed one.
        case upToDate
        /// The script declares no @updateURL/@downloadURL to check (e.g. pasted source).
        case noURL
        /// Network or parse failure — left the installed script untouched (fail closed).
        case failed
    }

    private let scriptStore: ScriptStore
    private let parser = ScriptMetadataParser()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(scriptStore: ScriptStore = BrownBearServices.shared.scriptStore) {
        self.scriptStore = scriptStore
    }

    /// Check every updatable script and re-install those with a newer remote @version. Returns the
    /// display names that were updated (for a user-facing summary).
    ///
    /// - Parameter respectOptOut: when `true` (the automatic pass), skip scripts the user has
    ///   individually excluded via `overrides.autoUpdate == false`. A manual "check all" passes
    ///   `false` to check everything regardless of per-script opt-out.
    @discardableResult
    func checkForUpdates(respectOptOut: Bool = true) async -> [String] {
        let scripts = await scriptStore.all()
        var updated: [String] = []
        for script in scripts {
            if respectOptOut && script.overrides?.autoUpdate == false { continue }
            guard let source = await fetchNewerSource(for: script) else { continue }
            if (try? await scriptStore.updateSource(id: script.id, source: source)) != nil {
                updated.append(script.displayName)
            }
        }
        return updated
    }

    /// Manually check one script and apply an update if a newer @version exists. Always runs,
    /// ignoring the per-script auto-update opt-out (that flag governs only the automatic pass).
    /// Returns a precise outcome so the caller can tell the user *why* nothing changed.
    func checkForUpdate(_ script: UserScript) async -> UpdateOutcome {
        guard let urlString = script.metadata.downloadURL ?? script.metadata.updateURL,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .noURL }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let remoteSource = String(data: data, encoding: .utf8),
              let remoteMeta = try? parser.parse(remoteSource) else { return .failed }
        guard Self.isVersion(remoteMeta.version, newerThan: script.metadata.version) else { return .upToDate }
        guard (try? await scriptStore.updateSource(id: script.id, source: remoteSource)) != nil else {
            return .failed
        }
        return .updated(remoteMeta.version ?? "?")
    }

    /// Fetch the remote source for `script` if its @version is newer than the installed one; else nil.
    private func fetchNewerSource(for script: UserScript) async -> String? {
        guard let urlString = script.metadata.downloadURL ?? script.metadata.updateURL,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let remoteSource = String(data: data, encoding: .utf8),
              let remoteMeta = try? parser.parse(remoteSource),
              Self.isVersion(remoteMeta.version, newerThan: script.metadata.version) else { return nil }
        return remoteSource
    }

    /// Compare dot/dash-separated numeric versions ("1.2.10" > "1.2.9"). A nil/unparseable remote
    /// version is never considered newer (fail closed — we don't replace a script on a bad fetch).
    static func isVersion(_ remote: String?, newerThan local: String?) -> Bool {
        guard let remote else { return false }
        let remoteParts = components(remote)
        let localParts = components(local ?? "0")
        for index in 0..<max(remoteParts.count, localParts.count) {
            let remoteValue = index < remoteParts.count ? remoteParts[index] : 0
            let localValue = index < localParts.count ? localParts[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { Int($0.filter(\.isNumber)) ?? 0 }
    }
}
