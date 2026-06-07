//
//  ExtensionStoreSource.swift
//  BrownBear
//
//  One unified type for "an extension you can install from a store page or pasted link" — Chrome Web
//  Store, Microsoft Edge Add-ons, or Mozilla Add-ons (Firefox). It centralizes detection, the
//  download (CRX or XPI — both flow through WebExtensionArchive), and the stable per-source store id
//  used to track "already installed". The in-page banner and the dashboard's paste-a-link both use it.
//

import Foundation

enum ExtensionStoreSource: Equatable {
    case chrome(id: String)
    case edge(id: String)
    case firefox(slug: String)

    /// Detect an installable store *detail* page from a navigated URL. nil for non-store/non-detail.
    static func detect(_ url: URL) -> ExtensionStoreSource? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "chromewebstore.google.com" || (host == "chrome.google.com" && url.path.hasPrefix("/webstore")) {
            return ChromeWebStore.extensionID(from: url.absoluteString).map { .chrome(id: $0) }
        }
        if host == "microsoftedge.microsoft.com", url.path.contains("/addons/detail/") {
            return EdgeAddons.extensionID(from: url.absoluteString).map { .edge(id: $0) }
        }
        if host.hasSuffix("addons.mozilla.org") {
            return FirefoxAddons.slug(from: url.absoluteString).map { .firefox(slug: $0) }
        }
        return nil
    }

    /// Detect from a pasted link OR a bare Chrome id (the dashboard's "install from store" field).
    static func detect(fromInput input: String) -> ExtensionStoreSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, let source = detect(url) { return source }
        if ChromeWebStore.isExtensionID(trimmed) { return .chrome(id: trimmed) }
        return nil
    }

    /// True for ANY store page (detail or not) — used to force a desktop UA across the whole store.
    static func isStoreURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && url.path.hasPrefix("/webstore"))
            || host == "microsoftedge.microsoft.com"
            || host.hasSuffix("addons.mozilla.org")
    }

    /// A stable id used to record/look up an install. Chrome stays the bare id (backward-compatible);
    /// Edge/Firefox are namespaced so a same-looking id from different stores can't collide.
    var storeID: String {
        switch self {
        case .chrome(let id): return id
        case .edge(let id): return "edge:" + id
        case .firefox(let slug): return "firefox:" + slug
        }
    }

    var storeLabel: String {
        switch self {
        case .chrome: return "Chrome Web Store"
        case .edge: return "Edge Add-ons"
        case .firefox: return "Firefox Add-ons"
        }
    }

    /// Download the package bytes (CRX for Chrome/Edge, XPI for Firefox), ready for WebExtensionStore.
    func downloadArchive() async throws -> Data {
        switch self {
        case .chrome(let id): return try await ChromeWebStore.downloadCRX(forInput: id)
        case .edge(let id): return try await EdgeAddons.downloadCRX(id: id)
        case .firefox(let slug): return try await FirefoxAddons.downloadXPI(slug: slug)
        }
    }
}
