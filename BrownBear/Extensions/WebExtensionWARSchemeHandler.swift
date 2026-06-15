//
//  WebExtensionWARSchemeHandler.swift
//  BrownBear
//
//  Serves an extension's `web_accessible_resources` to NORMAL browsing tabs — the case where a content
//  script does `chrome.runtime.getURL('icon.png')` and the PAGE then loads that `chrome-extension://` URL
//  (an <img>/<script>/fetch). The main browsing config otherwise has NO handler for that scheme, so those
//  loads fail outright; this closes that gap.
//
//  Unlike WebExtensionSchemeHandler (bound to ONE extension, serving its own popup/options pages), the main
//  browsing config is shared across every tab and every installed extension, so this handler resolves the
//  extension by the URL's id and FAILS CLOSED: it serves a file ONLY when the path matches the manifest's
//  `web_accessible_resources` `resources` AND the requesting document origin matches their `matches`. So it
//  can only ever serve resources the extension explicitly published, to the origins it allowed — worst case
//  it serves nothing (the status quo). `store.fileSync` adds a second, independent traversal guard.
//
//  Threading mirrors WebExtensionSchemeHandler: start/stop arrive on the main thread, a task may only be
//  messaged between them, so live tasks are tracked in a main-thread-only set and delivery is gated on it.
//

import WebKit

@MainActor
final class WebExtensionWARSchemeHandler: NSObject, WKURLSchemeHandler {

    private let store: WebExtensionStore
    private var liveTasks: Set<ObjectIdentifier> = []

    init(store: WebExtensionStore = BrownBearServices.shared.webExtensionStore) {
        self.store = store
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let extensionID = url.host,
              ChromeWebStore.isExtensionID(extensionID) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let path = String(url.path.drop(while: { $0 == "/" }))
        // A WAR path is matched as ALREADY-RESOLVED (Chrome resolves dot-segments before matching). Reject
        // any `.`/`..` segment up front: otherwise a `*` glob (e.g. "img/*", or the common "*") would span a
        // traversal like "img/../background.js" into a NON-WAR file that's still inside the extension dir —
        // fileSync's guard only blocks escapes OUT of the dir, not reads of undeclared files within it.
        guard Self.isTraversalFree(path) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let pageURL = task.request.mainDocumentURL?.absoluteString
        let id = ObjectIdentifier(task)
        liveTasks.insert(id)
        let store = self.store
        Task { @MainActor in
            let ext = await store.ext(for: extensionID)
            // Fail closed: a declared web-accessible resource of an ENABLED extension, to a matching origin.
            guard let ext, ext.enabled, let manifest = ext.manifest,
                  Self.isWebAccessible(path: path, pageURL: pageURL, manifest: manifest),
                  let data = store.fileSync(extensionID: extensionID, path: path) else {
                self.fail(task, id: id)
                return
            }
            guard self.liveTasks.contains(id) else { return }
            let headers = ["Content-Type": WebExtensionSchemeHandler.mimeType(forPath: path),
                           "Content-Length": String(data.count),
                           "Access-Control-Allow-Origin": "*"]
            if let response = HTTPURLResponse(url: url, statusCode: 200,
                                              httpVersion: "HTTP/1.1", headerFields: headers) {
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
                self.liveTasks.remove(id)
            } else {
                self.fail(task, id: id)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, id: ObjectIdentifier) {
        guard liveTasks.contains(id) else { return }
        liveTasks.remove(id)
        task.didFailWithError(URLError(.resourceUnavailable))
    }

    // MARK: - Pure gating (the security-critical logic — unit-tested)

    /// True only when `path` is a declared `web_accessible_resources` entry AND the requesting page
    /// (`pageURL`) matches that entry's `matches`. Fails closed: an undeterminable page origin passes only an
    /// `<all_urls>` entry (the MV2 default). Reuses URLMatcher (the @match matcher) for the origin patterns.
    /// CAVEAT: `pageURL` is the task's `mainDocumentURL` (the TOP document) — WKWebView doesn't expose the
    /// requesting subframe's origin on a scheme task, so a resource declared for the top origin can also be
    /// loaded from a cross-origin iframe embedded in it. A WKWebView hardening gap, not a fail-closed break.
    /// `nonisolated` (pure over its args + the nonisolated URLMatcher) so it's callable from tests/handler.
    nonisolated static func isWebAccessible(path: String, pageURL: String?,
                                            manifest: WebExtensionManifest) -> Bool {
        for entry in manifest.webAccessibleResources
        where entry.resources.contains(where: { pathMatchesGlob(path, $0) }) {
            if entry.matches.contains("<all_urls>") { return true }
            if let pageURL, !entry.matches.isEmpty,
               URLMatcher(matches: entry.matches, includes: [], excludes: [],
                          excludeMatches: []).matches(pageURL) {
                return true
            }
        }
        return false
    }

    /// Whether `path` is free of `.`/`..` segments (i.e. already-resolved). A traversal segment must be
    /// rejected BEFORE the glob match, or a `*` could span it into a non-WAR file inside the dir. Pure.
    nonisolated static func isTraversalFree(_ path: String) -> Bool {
        !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    /// A Chrome `web_accessible_resources` glob: `*` matches any run of characters (including `/`); the whole
    /// path must match. Everything else is literal.
    nonisolated static func pathMatchesGlob(_ path: String, _ glob: String) -> Bool {
        let regex = "^" + glob.components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: ".*") + "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
