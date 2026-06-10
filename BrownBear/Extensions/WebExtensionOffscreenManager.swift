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

        /// Resolve the wait as failed from a NON-delegate source (the load timeout). Idempotent — if a
        /// real terminal callback already fired, this is a no-op.
        func fail(_ message: String) { finish(message) }

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
        /// The web content process crashed/was jetsammed mid-load. WebKit may deliver NO didFinish/didFail
        /// in this case, so without this the load would hang forever (the offscreen web view is an
        /// off-screen, backgrounded page — a prime jetsam target). Resolve it as a failure.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish("the offscreen document's web content process terminated")
        }
    }

    private var documents: [String: Document] = [:]
    /// The generation of the in-flight create for an extension (absent if none is building). Each
    /// createDocument bumps it; closeDocument bumps it to CANCEL an in-flight build. A builder that
    /// finds the generation changed out from under it (a newer create, or a close) bails and tears down.
    /// This is finer than a bare "is creating" flag: it distinguishes "MY build is still current" from
    /// "a different build owns the slot now", so a close→create interleave during the load `await` can't
    /// let a stale builder commit a document the user already closed.
    private var inFlight: [String: Int] = [:]
    private var generationCounter = 0
    /// Bounds a single offscreen load so a wedged/never-terminating navigation can't hang createDocument
    /// (and the worker's Promise) forever. The renderer-crash callback covers the common case; this is
    /// the catch-all for any load that neither finishes nor fails.
    private static let loadTimeout: UInt64 = 20_000_000_000   // 20s in nanoseconds

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
        // Chrome's single-document rule: reject if one is committed OR another create is in flight.
        guard documents[ext.id] == nil, inFlight[ext.id] == nil else {
            return ["error": "Only a single offscreen document may be created."]
        }
        guard let container else {
            return ["error": "Offscreen documents are unavailable (no host window)."]
        }
        guard let cleanPath = Self.sanitizedPath(extID: ext.id, rawPath: path) else {
            return ["error": "Invalid offscreen document URL."]
        }
        // Claim the slot with a unique generation BEFORE the first await. A later create or a close
        // changes inFlight[ext.id], which this builder detects after the await. Cleared on return only
        // if it's still ours (a superseding create must keep its own claim).
        generationCounter += 1
        let generation = generationCounter
        inFlight[ext.id] = generation
        defer { if inFlight[ext.id] == generation { inFlight.removeValue(forKey: ext.id) } }

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

        // Race the load against a deadline; whichever resolves the observer first wins (idempotent).
        let timeoutTask = Task { @MainActor [weak observer] in
            try? await Task.sleep(nanoseconds: Self.loadTimeout)
            observer?.fail("offscreen document load timed out")
        }
        let loadError = await observer.wait()
        timeoutTask.cancel()

        let tearDown = {
            session.invalidate()
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        if let loadError {
            tearDown()
            return ["error": "Failed to load offscreen document: \(loadError)"]
        }
        // A close() (or a superseding create) could have changed the slot during the load await; if this
        // build is no longer the current generation, it was cancelled — discard it.
        guard inFlight[ext.id] == generation, documents[ext.id] == nil else {
            tearDown()
            return ["error": "Offscreen document was closed before it finished loading."]
        }
        documents[ext.id] = Document(session: session, webView: webView, url: url,
                                     reasons: cleanReasons, loadObserver: observer)
        return [:]
    }

    /// Close `ext`'s offscreen document (chrome.offscreen.closeDocument). Returns true if it closed a
    /// committed document OR cancelled an in-flight create; false only if there was genuinely nothing.
    /// Tears the page session down so its ports disconnect and it stops receiving pushed events.
    @discardableResult
    func closeDocument(extensionID: String) -> Bool {
        // Cancel any in-flight create (bump the generation so the awaiting builder bails and tears down).
        let cancelledCreate = inFlight.removeValue(forKey: extensionID) != nil
        guard let doc = documents.removeValue(forKey: extensionID) else { return cancelledCreate }
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
    /// `nonisolated` (the work is pure) + `internal` so the security behavior is unit-tested directly
    /// from a synchronous, non-actor-isolated context.
    nonisolated static func sanitizedPath(extID: String, rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        // Strip the extension's own resource prefix under EITHER scheme (chrome- / moz-extension) so a
        // Firefox build's own-origin path isn't rejected by the colon guard below.
        let ownPrefix = WebExtensionSchemeHandler.extensionSchemes
            .map { "\($0)://\(extID)/" }.first { path.hasPrefix($0) }
        if let ownPrefix {
            path = String(path.dropFirst(ownPrefix.count))
        } else if path.contains(":") {
            // Any colon in a non-own-prefix path is a smuggled scheme — `https://`, `file://`, but also
            // single-colon ones like `javascript:` / `data:` / `mailto:`. A packaged relative resource
            // path never contains a colon, so reject outright.
            return nil
        }
        // Drop any query/fragment so traversal can't hide after a `?`/`#`, then strip leading slashes.
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }
        // Reject control characters / NUL (a `\0` truncates at the C-string boundary; controls have no
        // place in a packaged path).
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
        // The traversal check must see THROUGH percent-encoding: WebExtensionSchemeHandler reads
        // `url.path`, which Foundation percent-DECODES, so `%2e%2e/x` / `a%2f..%2fb` / `a%5c..%5cb` would
        // otherwise reach the store as `../`. Decode (repeatedly, to defeat double-encoding), split on
        // BOTH `/` and `\`, and reject any `.`/`..` segment. We still return the ORIGINAL path (legit
        // encoded filenames like `my%20file.html` stay intact); only the check runs on the decoded form.
        var decoded = path
        for _ in 0..<3 {
            guard let once = decoded.removingPercentEncoding, once != decoded else { break }
            decoded = once
        }
        if decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
        // A colon surviving in the decoded path (e.g. own-prefix remainder, or a `%3a`-smuggled scheme)
        // is likewise not a packaged resource path — reject.
        if decoded.contains(":") { return nil }
        let segments = decoded.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        if segments.contains("..") || segments.contains(".") { return nil }
        return path
    }
}
