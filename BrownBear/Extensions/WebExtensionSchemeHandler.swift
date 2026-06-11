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

    /// The Chrome-build scheme — the canonical default, and what non-extension-scoped call sites use.
    /// Not a WebKit built-in, so it's safe to register a handler for it.
    static let scheme = "chrome-extension"
    /// The Firefox-build scheme. Firefox bundles hardcode `moz-extension:` as their internal-page
    /// protocol; also not a WebKit built-in, so a handler can be registered for it too. (We deliberately
    /// do NOT serve under `safari-web-extension://` — that IS reserved by WebKit and rejects a handler.)
    static let firefoxScheme = "moz-extension"
    /// Every scheme an extension page can be served under. Used by checks that must accept either build.
    static let extensionSchemes: Set<String> = [scheme, firefoxScheme]

    /// True for a URL scheme that hosts an extension's own pages/resources (chrome- or moz-extension).
    /// Use at CHECK sites ("is this an extension URL?"); use a specific `WebExtension.scheme` to BUILD one.
    static func isExtensionScheme(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        return extensionSchemes.contains(candidate.lowercased())
    }

    /// The scheme THIS handler serves (`chrome-extension` for Chrome builds, `moz-extension` for Firefox).
    /// WebKit routes only this scheme's requests here, so it also stamps the CORS origin on responses.
    let scheme: String

    private let store: WebExtensionStore
    /// The ONE extension this handler may serve. A popup/options page running at
    /// `chrome-extension://<allowedExtensionID>/` must not be able to fetch another extension's
    /// packaged files by requesting `chrome-extension://<other>/…` (WebKit routes every
    /// chrome-extension request in the web view through this single handler).
    private let allowedExtensionID: String
    /// Identifiers of tasks WebKit has started and not yet stopped. Main-thread only.
    private var liveTasks: Set<ObjectIdentifier> = []

    init(extensionID: String, scheme: String = WebExtensionSchemeHandler.scheme,
         store: WebExtensionStore = BrownBearServices.shared.webExtensionStore) {
        self.allowedExtensionID = extensionID
        self.scheme = scheme
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

        // Captured on the main thread (a WKURLSchemeTask's request must not be read off it) for the
        // service-worker fetch fallback below. absoluteString keeps the query — Stylus's /data?… handler
        // reads dark/frameId/url from it.
        let requestMethod = urlSchemeTask.request.httpMethod ?? "GET"
        let requestHeaders = urlSchemeTask.request.allHTTPHeaderFields ?? [:]
        let absoluteURLString = url.absoluteString

        // A page module graph we pre-linked for this extension is served from memory under a synthetic
        // `__bb-page-bundle/<hash>.js` path (no packaged file). This must run BEFORE the store read so the
        // generated bundle, which has no file on disk, resolves. See WebExtensionPageModuleBundler.
        if let bundleJS = WebExtensionPageModuleBundler.cachedBundle(extensionID: extensionID, path: resolvedPath) {
            liveTasks.remove(key)
            let data = Data(bundleJS.utf8)
            let headers = Self.responseHeaders(path: resolvedPath, dataCount: data.count,
                                               extensionID: extensionID, csp: nil, scheme: self.scheme)
            if let response = HTTPURLResponse(url: url, statusCode: 200,
                                              httpVersion: "HTTP/1.1", headerFields: headers) {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else {
                logResourceFailure(level: "error", reason: "bad response for generated bundle \(resolvedPath)")
                urlSchemeTask.didFailWithError(BrownBearError.bridgeRejected("bad response"))
            }
            return
        }

        let isHTMLPage = Self.mimeType(forPath: resolvedPath).hasPrefix("text/html")
        let store = self.store
        Task { [weak self] in
            guard let self else { return }
            let data = await store.file(extensionID: extensionID, path: resolvedPath)
            // Only HTML documents carry the page CSP (it governs the document + its subresources); fetch
            // the declared policy lazily so JS/CSS/image responses don't touch the store actor twice.
            let csp = isHTMLPage ? await store.ext(for: extensionID)?.manifest?.contentSecurityPolicy : nil
            // If this HTML page loads ES-module scripts (which WKWebView won't run over our custom scheme),
            // pre-link them into a same-origin classic bundle and serve the rewritten HTML; nil falls back
            // to the original bytes. Done off the main thread (this Task), before delivery.
            var payload = data
            if isHTMLPage, let data, let htmlString = String(data: data, encoding: .utf8) {
                let rewritten = WebExtensionPageModuleBundler.rewrittenHTML(
                    extensionID: extensionID, htmlPath: resolvedPath, html: htmlString, scheme: self.scheme,
                    moduleSource: { store.fileSync(extensionID: extensionID, path: $0) },
                    log: { level, message in
                        Task { await BrownBearServices.shared.webExtensionRuntime
                            .logFromPage(extensionID: extensionID, level: level, message: message) }
                    })
                if let rewritten { payload = Data(rewritten.utf8) }
            }
            // No packaged file? Give this extension's service worker the chance to synthesize the
            // response from its `fetch` handler (Stylus serves chrome-extension://<id>/data?… this way).
            // Returns nil quickly for extensions with no fetch handler / no running worker.
            var swResponse: WebExtensionBackgroundContext.ServiceWorkerFetchResponse?
            if payload == nil {
                let headersJSON = (try? JSONSerialization.data(withJSONObject: requestHeaders))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                swResponse = await BrownBearServices.shared.webExtensionRuntime.serviceWorkerFetch(
                    extensionID: extensionID, urlString: absoluteURLString,
                    method: requestMethod, headersJSON: headersJSON)
            }
            await MainActor.run {
                guard self.liveTasks.contains(key) else { return }   // stopped while we were reading
                self.liveTasks.remove(key)
                if let data = payload {
                    let headers = Self.responseHeaders(path: resolvedPath, dataCount: data.count,
                                                       extensionID: extensionID, csp: csp, scheme: self.scheme)
                    if let response = HTTPURLResponse(url: url, statusCode: 200,
                                                      httpVersion: "HTTP/1.1", headerFields: headers) {
                        urlSchemeTask.didReceive(response)
                        urlSchemeTask.didReceive(data)
                        urlSchemeTask.didFinish()
                    } else {
                        self.logResourceFailure(level: "error", reason: "bad response for \(resolvedPath)")
                        urlSchemeTask.didFailWithError(BrownBearError.bridgeRejected("bad response"))
                    }
                } else if let swResponse {
                    self.deliver(serviceWorkerResponse: swResponse, url: url, extensionID: extensionID,
                                 resolvedPath: resolvedPath, task: urlSchemeTask)
                } else {
                    // A missing packaged resource is the canonical blank-popup / dead-options cause and the
                    // ONE place the failed path is known for certain (a missing subresource fires no JS error
                    // event, so nothing else can surface it). Log it so the Logs tab names the file.
                    self.logResourceFailure(level: "warn", reason: "resource not found: \(resolvedPath)")
                    urlSchemeTask.didFailWithError(BrownBearError.bridgeRejected("not found: \(resolvedPath)"))
                }
            }
        }
    }

    /// Deliver a response the extension's service worker synthesized for an unpackaged path. Carries the
    /// worker's status + headers, backfills Content-Type/Length and the extension-scoped CORS origin, and
    /// streams the (possibly empty) body. Main-actor only — messages a live WKURLSchemeTask.
    @MainActor
    private func deliver(serviceWorkerResponse sw: WebExtensionBackgroundContext.ServiceWorkerFetchResponse,
                         url: URL, extensionID: String, resolvedPath: String, task: WKURLSchemeTask) {
        var headers = sw.headers
        headers["Content-Length"] = "\(sw.body.count)"
        headers["Access-Control-Allow-Origin"] = "\(self.scheme)://\(extensionID)"
        let hasContentType = headers.keys.contains { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
        if !hasContentType { headers["Content-Type"] = Self.mimeType(forPath: resolvedPath) }
        let status = sw.status > 0 ? sw.status : 200
        if let response = HTTPURLResponse(url: url, statusCode: status,
                                          httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(response)
            if !sw.body.isEmpty { task.didReceive(sw.body) }
            task.didFinish()
        } else {
            self.logResourceFailure(level: "error", reason: "bad worker response for \(resolvedPath)")
            task.didFailWithError(BrownBearError.bridgeRejected("bad worker response"))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func fail(_ task: WKURLSchemeTask, key: ObjectIdentifier, reason: String) {
        guard liveTasks.contains(key) else { return }
        liveTasks.remove(key)
        logResourceFailure(level: "error", reason: reason)
        task.didFailWithError(BrownBearError.bridgeRejected(reason))
    }

    /// Surface a resource-load failure to the Logs tab. This handler is the only place a missing/denied
    /// chrome-extension resource is known for certain — a 404 of the popup/options HTML or a subresource
    /// is the canonical blank-page cause and fires NO JS error event, so without this it is fully silent.
    private func logResourceFailure(level: String, reason: String) {
        let extID = allowedExtensionID
        Task { await BrownBearServices.shared.webExtensionRuntime
            .logFromPage(extensionID: extID, level: level, message: "extension resource failed: \(reason)") }
    }

    /// The response headers for a served extension resource: content type, content length, and CORS
    /// scoped to the extension's OWN origin (not "*"). An HTML PAGE additionally carries the manifest's
    /// Content-Security-Policy when one is declared, so a CSP-declaring extension's inline-script / eval
    /// restrictions actually apply (matching Chrome); non-HTML resources never carry it, and a CSP-less
    /// manifest is left unchanged (no default injected — that would break pages that work without one).
    /// Pure mapping — unit-tested directly (the WKURLSchemeHandler response path needs a live web view).
    static func responseHeaders(path: String, dataCount: Int, extensionID: String, csp: String?,
                                scheme: String = WebExtensionSchemeHandler.scheme) -> [String: String] {
        let contentType = mimeType(forPath: path)
        var headers = [
            "Content-Type": contentType,
            "Content-Length": "\(dataCount)",
            "Access-Control-Allow-Origin": "\(scheme)://\(extensionID)"
        ]
        if contentType.hasPrefix("text/html"), let csp, !csp.isEmpty {
            headers["Content-Security-Policy"] = csp
        }
        return headers
    }

    /// A small content-type table — enough for the HTML/JS/CSS/image/font assets an extension page
    /// loads. Anything unknown falls back to octet-stream.
    static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        // Bitwarden loads a .wasm via WebAssembly.instantiateStreaming, which REQUIRES the response carry
        // `application/wasm`; without this case it got octet-stream and fell back to the slower
        // instantiate() path with a console error.
        case "wasm": return "application/wasm"
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
