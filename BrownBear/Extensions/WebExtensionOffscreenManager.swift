//
//  WebExtensionOffscreenManager.swift
//  BrownBear
//
//  chrome.offscreen — a hidden, REAL-DOM document for a Manifest V3 service worker.
//
//  An MV3 service worker has no DOM (no `window`/`document`), so anything that parses HTML, uses
//  `DOMParser`/canvas/audio, or reads layout has to run in an offscreen document: a hidden page at a
//  packaged extension URL that talks to the worker over chrome.runtime messaging. Chrome backs it with
//  a real (invisible) page; we do the faithful thing and host it in a hidden `WKWebView`, reusing the
//  exact popup/options engine (`WebExtensionPageSession` + the per-extension scheme handler + the
//  brownbear-webext-page.js runtime). A headless JSContext can never BE a DOM — this is why the old
//  `chrome.offscreen` stub had to reject; a hidden WKWebView is the only iOS mechanism that gives one.
//
//  Lifecycle: the worker calls `chrome.offscreen.createDocument` → `__bb_offscreen` native →
//  `WebExtensionRuntime.createOffscreenDocument` → here. We mint a page session, build its WKWebView,
//  add it OFF-SCREEN to the browser's view (off-screen coordinates keep JS/timers live — unlike
//  `isHidden`/not-in-window, which WebKit may suspend), load the URL, and resolve once it has loaded.
//  Chrome permits a SINGLE offscreen document per extension; a second createDocument rejects. The
//  document is torn down on closeDocument or when the extension is disabled/uninstalled (the runtime
//  calls `close(extensionID:)` from its reload teardown).
//

import UIKit
import WebKit

@MainActor
final class WebExtensionOffscreenManager {

    /// One live offscreen document: the page engine, its hidden web view, and the load observer kept
    /// alive for the view's lifetime (a WKWebView does not retain its navigationDelegate).
    private final class Document {
        let session: WebExtensionPageSession
        let webView: WKWebView
        let url: URL
        let reasons: [String]
        let loadObserver: LoadObserver
        init(session: WebExtensionPageSession, webView: WKWebView, url: URL,
             reasons: [String], loadObserver: LoadObserver) {
            self.session = session
            self.webView = webView
            self.url = url
            self.reasons = reasons
            self.loadObserver = loadObserver
        }
    }

    /// Bridges WKNavigationDelegate's load callbacks to a one-shot continuation, so `createDocument`
    /// can await the document being ready (Chrome resolves createDocument only once the page is loaded).
    private final class LoadObserver: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<String?, Never>?
        private var finished = false

        /// Suspend until the page finishes loading. Returns nil on success, or an error message on
        /// failure. Safe if the load already completed before `wait()` (resumes immediately).
        func wait() async -> String? {
            if finished { return loadError }
            return await withCheckedContinuation { continuation = $0 }
        }

        private var loadError: String?
        private func finish(_ error: String?) {
            guard !finished else { return }   // first terminal callback wins (resume the continuation once)
            finished = true
            loadError = error
            let resume = continuation
            continuation = nil
            resume?.resume(returning: error)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(error.localizedDescription)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            finish(error.localizedDescription)
        }
    }

    private var documents: [String: Document] = [:]
    /// Extensions mid-creation, so two overlapping createDocument calls can't both pass the single-doc
    /// guard during the `await` window before the document lands in `documents`.
    private var creating: Set<String> = []

    /// Whether `ext` currently has an offscreen document (chrome.offscreen.hasDocument).
    func hasDocument(extensionID: String) -> Bool { documents[extensionID] != nil }

    /// Create the single offscreen document for `ext`. Returns an empty dict on success, or
    /// `["error": <message>]` carrying the message the worker's createDocument Promise should reject
    /// with (mirroring Chrome's rejection texts where applicable). `container` is the host view the
    /// hidden web view is parented into (off-screen) to keep its JS alive — nil if there's no window.
    func createDocument(ext: WebExtension, path: String, reasons: [String], justification: String,
                        container: UIView?) async -> [String: Any] {
        let cleanReasons = reasons.filter { !$0.isEmpty }
        guard !cleanReasons.isEmpty else {
            return ["error": "Creating an offscreen document requires at least one reason."]
        }
        guard !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "Creating an offscreen document requires a justification."]
        }
        guard documents[ext.id] == nil, !creating.contains(ext.id) else {
            return ["error": "Only a single offscreen document may be created."]
        }
        guard let container else {
            return ["error": "Offscreen documents are unavailable (no host window)."]
        }
        guard let cleanPath = Self.sanitizedPath(extID: ext.id, rawPath: path) else {
            return ["error": "Invalid offscreen document URL."]
        }
        // Reserve the slot for the duration of the async build (cleared on every return).
        creating.insert(ext.id)
        defer { creating.remove(ext.id) }

        let session = WebExtensionPageSession(ext: ext, kind: .offscreen, path: cleanPath)
        guard let url = session.pageURL else { return ["error": "Invalid offscreen document URL."] }

        let configuration = await session.makeConfiguration()
        // Off-screen coordinates (not isHidden / not detached) so WebKit keeps the page's JS + timers
        // running. A real non-zero size lets layout-dependent DOM APIs work.
        let frame = CGRect(x: -20_000, y: -20_000, width: 360, height: 600)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        let observer = LoadObserver()
        webView.navigationDelegate = observer
        container.insertSubview(webView, at: 0)   // behind all browser chrome
        session.bind(to: webView)
        webView.load(URLRequest(url: url))

        if let loadError = await observer.wait() {
            session.invalidate()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            return ["error": "Failed to load offscreen document: \(loadError)"]
        }
        // A close() could have raced in during the load await; honor it.
        guard creating.contains(ext.id) else {
            session.invalidate()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            return ["error": "Offscreen document was closed before it finished loading."]
        }
        documents[ext.id] = Document(session: session, webView: webView, url: url,
                                     reasons: cleanReasons, loadObserver: observer)
        return [:]
    }

    /// Close `ext`'s offscreen document (chrome.offscreen.closeDocument). Returns false if there was
    /// none. Tears the page session down so its ports disconnect and it stops receiving pushed events.
    @discardableResult
    func closeDocument(extensionID: String) -> Bool {
        creating.remove(extensionID)   // cancel an in-flight create (the awaiting builder will bail)
        guard let doc = documents.removeValue(forKey: extensionID) else { return false }
        doc.session.invalidate()
        doc.webView.navigationDelegate = nil
        doc.webView.stopLoading()
        doc.webView.removeFromSuperview()
        return true
    }

    /// Teardown hook for the runtime when an extension is disabled/uninstalled. Idempotent.
    func close(extensionID: String) { closeDocument(extensionID: extensionID) }

    // MARK: - Path sanitation

    /// Resolve the caller-supplied offscreen `url` to a packaged path of THIS extension, rejecting
    /// path traversal and any absolute URL that isn't this extension's own `chrome-extension://` origin.
    /// Returns the cleaned relative path (the session turns it into the chrome-extension:// URL).
    /// `internal` (not private) so the security behavior is unit-tested directly.
    static func sanitizedPath(extID: String, rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let ownPrefix = "\(WebExtensionSchemeHandler.scheme)://\(extID)/"
        if path.hasPrefix(ownPrefix) {
            path = String(path.dropFirst(ownPrefix.count))
        } else if path.contains("://") {
            return nil   // an absolute URL of another scheme/extension — never serve it
        }
        // Drop any query/fragment so traversal can't hide after a `?`/`#`, then strip leading slashes.
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }
        // No `..` segment may escape the package.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains("..") { return nil }
        return path
    }
}
