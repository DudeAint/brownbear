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
}

@MainActor
final class Tab {

    /// Stable identity that survives web-view recreation.
    let id: UUID

    /// The renderer. Exposed so the browser controller can host it and assign nav/UI delegates.
    let webView: WKWebView

    /// Latest published state. Always kept in sync with `webView` via KVO.
    private(set) var state = NavigationState()

    /// Last rendered thumbnail, used by the tab grid. Refreshed when a tab resigns active.
    private(set) var snapshot: UIImage?

    weak var delegate: TabDelegate?

    private var observations: [NSKeyValueObservation] = []

    /// The destination this tab was asked to open before its web view had a chance to load,
    /// used so a freshly created tab can defer its first load until it is on screen.
    private(set) var pendingURL: URL?

    init(id: UUID = UUID(), configuration: WKWebViewConfiguration) {
        self.id = id
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.scrollView.contentInsetAdjustmentBehavior = .never
        self.webView.isOpaque = false
        self.webView.backgroundColor = BrownBearTheme.Palette.background
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

    func reload() {
        if webView.url == nil, let pendingURL { load(pendingURL) } else { webView.reload() }
    }

    func stopLoading() { webView.stopLoading() }

    func goBack() { webView.goBack() }

    func goForward() { webView.goForward() }

    // MARK: - Snapshot

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

    private func recomputeState() {
        var next = NavigationState()
        next.url = webView.url ?? pendingURL
        next.title = webView.title
        next.estimatedProgress = webView.estimatedProgress
        next.isLoading = webView.isLoading
        next.canGoBack = webView.canGoBack
        next.canGoForward = webView.canGoForward
        next.hasOnlySecureContent = webView.hasOnlySecureContent

        guard next != state else { return }
        state = next
        delegate?.tab(self, didChange: next)
    }
}
