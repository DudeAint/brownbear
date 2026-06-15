//
//  Tab.swift
//  BrownBear
//
//  A single browser tab: it owns one WKWebView and publishes its navigation state. We mirror
//  Chromium's WebState idea — the tab is the durable object; the web view is its renderer.
//  State changes are observed via KVO and pushed to a delegate so the chrome (omnibox,
//  toolbar, tab grid) can react without each surface observing WebKit directly.
//

import UIKit
import WebKit

/// An immutable snapshot of everything the chrome needs to render a tab's current state.
struct NavigationState: Equatable {
    var url: URL?
    var title: String?
    var estimatedProgress: Double = 0
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var hasOnlySecureContent: Bool = false

    /// Title to show in the tab grid / omnibox, falling back to the host then a placeholder.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    /// The host (without "www.") for a compact, Chrome-like omnibox display.
    var displayHost: String? {
        guard let host = url?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

@MainActor
protocol TabDelegate: AnyObject {
    /// The tab's observable navigation state changed (progress, title, url, secure, nav flags).
    func tab(_ tab: Tab, didChange state: NavigationState)
    /// The tab is showing the New Tab page and was asked to reload — the page is a `loadHTMLString`
    /// data document (about:blank) with nothing to reload, so the browser must regenerate it instead of
    /// reloading an empty document (which would blank the screen).
    func tabNeedsNewTabPage(_ tab: Tab)
    /// The pull-to-refresh control fired — accept it only if the user made a DELIBERATE downward pull at
    /// the top (the browser tracks the drag's overscroll), not a momentary bounce / momentum overshoot.
    func tabShouldAcceptPullToRefresh(_ tab: Tab) -> Bool
}

@MainActor
final class Tab {

    /// Stable identity that survives web-view recreation.
    let id: UUID

    /// Whether this is a private/incognito tab. Private tabs use a non-persistent website data store
    /// (cookies/cache wiped on close) and are never written to browsing history. Immutable: a tab's
    /// privacy is fixed at creation because it is baked into the web view's configuration.
    let isPrivate: Bool

    /// The renderer. Exposed so the browser controller can host it and assign nav/UI delegates.
    let webView: WKWebView

    /// Latest published state. Always kept in sync with `webView` via KVO.
    private(set) var state = NavigationState()

    /// Whether this tab is requesting the desktop site. Applied per-navigation via the nav delegate's
    /// `preferredContentMode` (the reliable way to get a desktop layout — a desktop UA alone is
    /// ignored by responsive sites) plus a desktop user-agent.
    var prefersDesktop = false

    /// Pinned tabs sort to the front of the tab grid and carry a pin glyph, so frequently-used pages
    /// stay put. Persisted across launches in the session record. Private tabs are never pinned.
    var isPinned = false

    /// The tab group this tab belongs to (Chrome/Safari-style), or nil if ungrouped. A tab is in at most
    /// one group; the group's definition (name + color) lives in TabManager.groups. Persisted across
    /// launches in the session record. Private tabs are never grouped.
    var groupID: UUID?

    /// Whether the user turned JavaScript OFF for this tab's site (per-site Shields). Applied
    /// per-navigation via the nav delegate's `WKWebpagePreferences.allowsContentJavaScript`. Seeded
    /// from the host's stored SiteSettings before content loads; defaults to false (JS enabled).
    var prefersJavaScriptDisabled = false

    /// Last rendered thumbnail, used by the tab grid. Refreshed when a tab resigns active.
    private(set) var snapshot: UIImage?

    weak var delegate: TabDelegate?

    private let refreshControl = UIRefreshControl()
    private var observations: [NSKeyValueObservation] = []

    /// The destination this tab was asked to open before its web view had a chance to load,
    /// used so a freshly created tab can defer its first load until it is on screen.
    private(set) var pendingURL: URL?

    /// The last real (committed) URL this tab displayed, retained across renderer loss. WebKit reclaims
    /// an off-screen tab's web-content process under memory pressure, after which `webView.url` reports
    /// nil; without this anchor the published state — and therefore the persisted session record — would
    /// collapse to "no URL", so the tab would restore as a blank New Tab even though it had a page (the
    /// retained thumbnail still showing the old site). It is only ever advanced to a fresher real URL,
    /// never nil'd by a transient renderer loss; it is cleared only when the tab is deliberately shown
    /// the New Tab page (`prepareForNewTabPage()`), so a genuine New Tab never resurrects an old URL.
    private(set) var lastCommittedURL: URL?

    /// Invoked once when this tab is closed (any close path), before its web view is freed. Lets an
    /// owner tear down state bound to the tab — e.g. a hosted extension page's chrome.runtime ports —
    /// while the runtime is still reachable. Generic so the Models layer stays free of feature knowledge.
    var onClose: (() -> Void)?

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration, isPrivate: Bool = false) {
        self.id = id
        self.isPrivate = isPrivate
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        // Web Inspector (Safari → Develop → this device): OFF by default — inspectable web content is a
        // privacy surface (anyone with the device + a Mac could read the page). Enable it from Settings to
        // debug page/userscript/extension execution directly (full console, breakpoints) instead of the
        // rate-limited Logs tab. iOS 16.4+ (our minimum). Absent default == off.
        if UserDefaults.standard.bool(forKey: "bbWebInspector") {
            self.webView.isInspectable = true
        }
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.isFindInteractionEnabled = true   // native Find-on-Page (iOS 16+)
        self.webView.scrollView.contentInsetAdjustmentBehavior = .never
        self.webView.isOpaque = false
        self.webView.backgroundColor = BrownBearTheme.Palette.background
        // Pull-to-refresh on web content: reload on overscroll; ended when the load settles
        // (see recomputeState). Tab isn't an NSObject, so use a UIAction rather than target-action.
        self.webView.scrollView.refreshControl = refreshControl
        refreshControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // UIRefreshControl fires on release-past-threshold, but a momentum overshoot at the top can
            // also trip it. Only reload on a deliberate pull (the delegate vouches for the drag); otherwise
            // cancel the spinner so a "scroll up, then back down" gesture doesn't refresh.
            if self.delegate?.tabShouldAcceptPullToRefresh(self) ?? true {
                self.reload()
            } else {
                self.refreshControl.endRefreshing()
            }
        }, for: .valueChanged)
        installObservations()
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    // MARK: - Navigation commands

    /// Load a URL now. If the web view is not yet in a window it still begins loading; WebKit
    /// queues the request until it has a renderer.
    func load(_ url: URL) {
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    /// Remember a URL to load once the tab becomes active (used for the initial tab).
    func setPendingURL(_ url: URL) {
        pendingURL = url
    }

    /// If a pending URL was queued, load it and clear the queue.
    func loadPendingURLIfNeeded() {
        guard let pendingURL else { return }
        load(pendingURL)
    }

    /// Activation entry point: start this tab's deferred load if one is queued; otherwise, if WebKit
    /// reclaimed the renderer while the tab was off-screen (web view blank, nothing pending) but the tab
    /// has a last-committed URL, reload that URL so a re-shown tab renders its page rather than a blank
    /// view. A normally-loaded tab (`webView.url` non-nil) and the New Tab page (`lastCommittedURL` nil)
    /// are both left untouched. Pending-first ordering guarantees we never kick off two loads at once.
    func loadPendingOrRecover() {
        if let pendingURL {
            load(pendingURL)
            return
        }
        if webView.url == nil, let lastCommittedURL {
            load(lastCommittedURL)
        }
    }

    /// Mark this tab as being shown the in-app New Tab page, forgetting any retained committed URL so the
    /// blank page is never mistaken for a renderer-reclaimed real page (and so `isShowingNewTabPage` reads
    /// true). Called by the browser when it loads the New Tab document into the tab.
    func prepareForNewTabPage() {
        lastCommittedURL = nil
    }

    /// True when this tab is showing the in-app New Tab page: it's loaded via `loadHTMLString(baseURL:
    /// nil)` so `webView.url` reports about:blank, there's no real navigation pending, AND there's no
    /// last-committed URL to recover — a real page whose renderer WebKit reclaimed (`webView.url` nil,
    /// `lastCommittedURL` set) is NOT the New Tab page, it's a tab awaiting a reload.
    var isShowingNewTabPage: Bool {
        pendingURL == nil && lastCommittedURL == nil &&
            (webView.url == nil || webView.url?.absoluteString == "about:blank")
    }

    func reload() {
        if isShowingNewTabPage {
            // Nothing to reload in an about:blank data document — ask the browser to rebuild the page,
            // otherwise reloading blanks the screen.
            delegate?.tabNeedsNewTabPage(self)
        } else if webView.url == nil {
            // The renderer hasn't loaded (a deferred first load) or was reclaimed by WebKit (process
            // terminated). Drive the load from whatever URL we still hold, newest intent first; fall back
            // to rebuilding the New Tab page only if the tab genuinely has no URL.
            if let pendingURL {
                load(pendingURL)
            } else if let lastCommittedURL {
                load(lastCommittedURL)
            } else {
                delegate?.tabNeedsNewTabPage(self)
            }
        } else {
            webView.reload()
        }
    }

    func stopLoading() { webView.stopLoading() }

    func goBack() { webView.goBack() }

    func goForward() { webView.goForward() }

    // MARK: - Snapshot

    /// Seed the title / url / thumbnail for a tab restored from the saved session, so the tab grid shows
    /// the real title and preview BEFORE the tab is activated and actually loads. The pending URL still
    /// drives the lazy load on activation; this only fills what the chrome shows in the meantime, and is
    /// replaced by the live page's real state the moment the tab loads. (recomputeState doesn't run again
    /// for an un-loaded tab, so the seeded values survive until then.)
    func restoreForDisplay(url: URL?, title: String?, snapshot: UIImage?) {
        if let url { state.url = url }
        if let title, !title.isEmpty { state.title = title }
        if let snapshot { self.snapshot = snapshot }
    }

    /// Capture a thumbnail of the current page for the tab grid. No-op if the view has no size.
    func refreshSnapshot(completion: (() -> Void)? = nil) {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { completion?(); return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
            completion?()
        }
    }

    // MARK: - KVO

    private func installObservations() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.recomputeState() },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.recomputeState() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.recomputeState() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.recomputeState() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.recomputeState() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.recomputeState() },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in self?.recomputeState() }
        ]
        recomputeState()
    }

    /// Resolve the URL the tab should publish, given the renderer's current URL, any queued pending load,
    /// and the last real URL the tab committed. Pure (no WebKit) so the renderer-loss fallback is unit-
    /// testable. Rules:
    /// - a real renderer URL is authoritative (the caller also records it as the new last-committed URL);
    /// - about:blank — the `loadHTMLString(baseURL: nil)` New Tab page — is not a real destination, so it
    ///   resolves to nil (the omnibox shows its placeholder) and does NOT resurrect a retained URL;
    /// - a nil renderer URL (deferred first load, or a renderer WebKit reclaimed) falls back to the
    ///   pending URL, then the last-committed URL, so the published state survives a transient renderer loss.
    nonisolated static func resolvedURL(webViewURL: URL?, pendingURL: URL?, lastCommittedURL: URL?) -> URL? {
        if let webViewURL {
            return webViewURL.absoluteString == "about:blank" ? nil : webViewURL
        }
        return pendingURL ?? lastCommittedURL
    }

    private func recomputeState() {
        var next = NavigationState()
        // Advance the retained anchor whenever the renderer reports a real (non-about:blank) URL, so a
        // later renderer loss can fall back to it. Never cleared here — only by prepareForNewTabPage().
        if let current = webView.url, current.absoluteString != "about:blank" {
            lastCommittedURL = current
        }
        next.url = Tab.resolvedURL(webViewURL: webView.url, pendingURL: pendingURL,
                                   lastCommittedURL: lastCommittedURL)
        next.title = webView.title
        next.estimatedProgress = webView.estimatedProgress
        next.isLoading = webView.isLoading
        next.canGoBack = webView.canGoBack
        next.canGoForward = webView.canGoForward
        next.hasOnlySecureContent = webView.hasOnlySecureContent

        guard next != state else { return }
        state = next
        if !next.isLoading, refreshControl.isRefreshing { refreshControl.endRefreshing() }
        delegate?.tab(self, didChange: next)
    }
}
