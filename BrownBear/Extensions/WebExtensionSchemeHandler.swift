//
//  WebExtensionSchemeHandler.swift
//  BrownBear
//
//  Serves `chrome-extension://<id>/<path>` out of an installed extension's packaged files, so an
//  extension's popup and options pages (and the relative scripts/styles/images they reference) load
//  in a WKWebView exactly as they would in Chrome. The URL host is the 32-char extension id; the
//  path is resolved against that extension's on-disk directory via WebExtensionStore (which already
//  contains traversal escapes), so one extension can never serve another's — or the app's — files.
//
//  Threading: WKURLSchemeHandler's start/stop are delivered on the main thread and a task may only
//  be messaged between them. We track live tasks in a main-thread-only set, read files off the
//  store actor, and hop back to main to deliver only if the task is still live.
//

import WebKit

final class WebExtensionSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The custom scheme. Not a WebKit built-in, so it's safe to register a handler for it.
    static let scheme = "chrome-extension"

    private let store: WebExtensionStore
    /// The ONE extension this handler may serve. A popup/options page running at
    /// `chrome-extension://<allowedExtensionID>/` must not be able to fetch another extension's
    /// packaged files by requesting `chrome-extension://<other>/…` (WebKit routes every
    /// chrome-extension request in the web view through this single handler).
    private let allowedExtensionID: String
    /// Identifiers of tasks WebKit has started and not yet stopped. Main-thread only.
    private var liveTasks: Set<ObjectIdentifier> = []

    init(extensionID: String, store: WebExtensionStore = BrownBearServices.shared.webExtensionStore) {
        self.allowedExtensionID = extensionID
        self.store = store
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        liveTasks.insert(key)

        guard let url = urlSchemeTask.request.url,
              let extensionID = url.host, ChromeWebStore.isExtensionID(extensionID) else {
            fail(urlSchemeTask, key: key, reason: "invalid chrome-extension URL")
            return
        }
        // Same-extension origin: serve only the extension this handler is bound to.
        guard extensionID == allowedExtensionID else {
            fail(urlSchemeTask, key: key, reason: "cross-extension request denied")
            return
        }

        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }
        let resolvedPath = path

        Task { [weak self] in
            guard let self else { return }
            let data = await self.store.file(extensionID: extensionID, path: resolvedPath)
            await MainActor.run {
                guard self.liveTasks.contains(key) else { return }   // stopped while we were reading
                self.liveTasks.remove(key)
                guard let data else {
                    urlSchemeTask.didFailWithError(BrownBearError.bridgeRejected("not found: \(resolvedPath)"))
                    return
                }
                // CORS scoped to this extension's own origin (not "*"), so even a same-handler
                // response isn't blanket-readable by another origin.
                let headers = [
                    "Content-Type": Self.mimeType(forPath: resolvedPath),
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "\(Self.scheme)://\(extensionID)"
                ]
                if let response = HTTPURLResponse(url: url, statusCode: 200,
                                                  httpVersion: "HTTP/1.1", headerFields: headers) {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                } else {
                    urlSchemeTask.didFailWithError(BrownBearError.bridgeRejected("bad response"))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func fail(_ task: WKURLSchemeTask, key: ObjectIdentifier, reason: String) {
        guard liveTasks.contains(key) else { return }
        liveTasks.remove(key)
        task.didFailWithError(BrownBearError.bridgeRejected(reason))
    }

    /// A small content-type table — enough for the HTML/JS/CSS/image/font assets an extension page
    /// loads. Anything unknown falls back to octet-stream.
    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
