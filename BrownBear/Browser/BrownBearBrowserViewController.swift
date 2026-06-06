//
//  BrownBearBrowserViewController.swift
//  BrownBear
//
//  The heart of the app. It composes the omnibox, progress bar, web content area, and bottom
//  toolbar, and binds them to the TabManager. It is the WKNavigationDelegate/WKUIDelegate for
//  every tab, so it observes the exact page lifecycle Module 2 will hook for script injection
//  (didStartProvisionalNavigation → didCommit → didFinish).
//

import UIKit
import WebKit

final class BrownBearBrowserViewController: UIViewController {

    // MARK: - Core model

    /// Owns the shared userscript runtime (Modules 2–3) plumbed into every tab's configuration.
    let injection = InjectionOrchestrator()
    private lazy var configurationFactory = WebViewConfigurationFactory(injection: injection)
    private lazy var tabManager = TabManager(configurationFactory: configurationFactory)
    private let omniboxClassifier = OmniboxInputClassifier()

    // MARK: - Chrome

    private let topChrome = UIView()
    private let omnibox = OmniboxView()
    private let progressBar = ProgressBar()
    private let contentContainer = UIView()
    private let toolbar = BrowserToolbar()

    /// The web view currently installed in the content container.
    private weak var installedWebView: WKWebView?

    /// `*.user.js` URLs the user chose to view as raw source instead of installing — let through once.
    private var viewSourceAllowOnce: Set<URL> = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
        tabManager.delegate = self
        omnibox.delegate = self
        toolbar.delegate = self
        injection.bridgeHost = self
        buildHierarchy()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    // MARK: - Public entry points (called by SceneDelegate)

    /// Open the first tab on the branded New Tab page if no tabs exist yet.
    func openInitialTabIfNeeded() {
        guard tabManager.isEmpty else { return }
        let tab = tabManager.createTab()
        loadNewTabPage(in: tab)
        refreshChrome()
    }

    /// Open a URL handed to us by the system (deep link / "open in").
    func handleExternalURL(_ url: URL) {
        let tab = tabManager.createTab(loading: url)
        tab.delegate = self
        tab.loadPendingURLIfNeeded()
        refreshChrome()
    }

    // MARK: - Layout

    private func buildHierarchy() {
        topChrome.backgroundColor = BrownBearTheme.Palette.chrome
        topChrome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topChrome)

        omnibox.translatesAutoresizingMaskIntoConstraints = false
        topChrome.addSubview(omnibox)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        contentContainer.backgroundColor = BrownBearTheme.Palette.background
        contentContainer.clipsToBounds = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let inset = BrownBearTheme.Metrics.chromeHorizontalInset
        let guide = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            topChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topChrome.topAnchor.constraint(equalTo: view.topAnchor),
            topChrome.bottomAnchor.constraint(equalTo: omnibox.bottomAnchor, constant: 8),

            omnibox.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
            omnibox.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            omnibox.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            omnibox.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.omniboxHeight),

            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: topChrome.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.progressBarHeight),

            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: guide.bottomAnchor,
                                         constant: -BrownBearTheme.Metrics.toolbarHeight)
        ])
    }

    // MARK: - Web view hosting

    /// Install the active tab's web view into the content container, removing the previous one.
    private func installActiveWebView() {
        installedWebView?.removeFromSuperview()
        installedWebView = nil

        guard let tab = tabManager.activeTab else { return }
        let webView = tab.webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        installedWebView = webView

        tab.delegate = self
        tab.loadPendingURLIfNeeded()
    }

    // MARK: - Chrome sync

    /// Push the active tab's state to every chrome surface.
    private func refreshChrome() {
        let state = tabManager.activeTab?.state ?? NavigationState()
        omnibox.update(with: state)
        toolbar.update(canGoBack: state.canGoBack,
                       canGoForward: state.canGoForward,
                       tabCount: tabManager.count)
        syncProgress(for: state)
    }

    private func syncProgress(for state: NavigationState) {
        if state.isLoading {
            progressBar.show()
            progressBar.setProgress(state.estimatedProgress, animated: true)
        } else if state.estimatedProgress >= 1 || state.url != nil {
            progressBar.complete()
        }
    }

    // MARK: - New Tab page

    private func loadNewTabPage(in tab: Tab) {
        tab.delegate = self
        tab.webView.loadHTMLString(Self.newTabHTML, baseURL: nil)
    }

    /// A branded, offline New Tab page so a fresh tab never shows a blank white void.
    private static let newTabHTML: String = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
      :root { color-scheme: light dark; }
      html,body{height:100%;margin:0;font-family:-apple-system,system-ui,sans-serif;}
      body{display:flex;flex-direction:column;align-items:center;justify-content:center;
           background:radial-gradient(circle at 50% 35%, #3A2417, #14110E);color:#F5EFE7;}
      .bear{font-size:72px;line-height:1;}
      h1{font-size:30px;font-weight:800;margin:18px 0 4px;letter-spacing:-.5px;}
      p{margin:0;color:#FFB454;font-size:16px;font-weight:600;}
      small{margin-top:22px;color:#B6A99C;font-size:13px;}
    </style></head><body>
      <div class="bear">🐻</div>
      <h1>BrownBear</h1>
      <p>Userscripts &amp; Power Browser</p>
      <small>Tap the address bar to search or enter a website.</small>
    </body></html>
    """
}

// MARK: - TabManagerDelegate

extension BrownBearBrowserViewController: TabManagerDelegate {
    func tabManager(_ manager: TabManager, didUpdate tabs: [Tab]) {
        toolbar.update(canGoBack: tabManager.activeTab?.state.canGoBack ?? false,
                       canGoForward: tabManager.activeTab?.state.canGoForward ?? false,
                       tabCount: tabs.count)
    }

    func tabManager(_ manager: TabManager, didActivate tab: Tab?, previous: Tab?) {
        previous?.refreshSnapshot()
        installActiveWebView()
        refreshChrome()
        // If the user closed the last tab, open a fresh New Tab page.
        if tab == nil {
            openInitialTabIfNeeded()
        }
    }
}

// MARK: - TabDelegate

extension BrownBearBrowserViewController: TabDelegate {
    func tab(_ tab: Tab, didChange state: NavigationState) {
        guard tab.id == tabManager.activeTabID else { return }
        omnibox.update(with: state)
        toolbar.update(canGoBack: state.canGoBack,
                       canGoForward: state.canGoForward,
                       tabCount: tabManager.count)
        syncProgress(for: state)
    }
}

// MARK: - OmniboxViewDelegate

extension BrownBearBrowserViewController: OmniboxViewDelegate {
    func omnibox(_ omnibox: OmniboxView, didSubmit text: String) {
        do {
            let destination = try omniboxClassifier.destination(for: text)
            let tab = tabManager.activeTab ?? tabManager.createTab()
            tab.delegate = self
            tab.load(destination.resolvedURL)
        } catch {
            presentError(error)
        }
    }

    func omniboxDidTapReloadStop(_ omnibox: OmniboxView) {
        guard let tab = tabManager.activeTab else { return }
        if tab.state.isLoading { tab.stopLoading() } else { tab.reload() }
    }

    func omniboxDidBeginEditing(_ omnibox: OmniboxView) {
        // Reserved for future omnibox suggestions UI.
    }
}

// MARK: - BrowserToolbarDelegate

extension BrownBearBrowserViewController: BrowserToolbarDelegate {
    func toolbarDidTapBack(_ toolbar: BrowserToolbar) { tabManager.activeTab?.goBack() }
    func toolbarDidTapForward(_ toolbar: BrowserToolbar) { tabManager.activeTab?.goForward() }

    func toolbarDidTapNewTab(_ toolbar: BrowserToolbar) {
        let tab = tabManager.createTab()
        loadNewTabPage(in: tab)
        refreshChrome()
        omnibox.beginEditing()
    }

    func toolbarDidTapTabs(_ toolbar: BrowserToolbar) {
        tabManager.activeTab?.refreshSnapshot { [weak self] in
            self?.presentTabGrid()
        }
    }

    func toolbarDidTapMenu(_ toolbar: BrowserToolbar) {
        presentMenu()
    }

    private func presentTabGrid() {
        let grid = BrownBearTabGridController(tabManager: tabManager)
        grid.gridDelegate = self
        grid.modalPresentationStyle = .fullScreen
        present(grid, animated: true)
    }

    private func presentMenu() {
        let tab = tabManager.activeTab
        let state = tab?.state ?? NavigationState()
        let url = state.url
        let menuState = BrowserMenuState(
            title: state.title,
            host: state.displayHost,
            isLoading: state.isLoading,
            isDesktopSite: tab?.webView.customUserAgent != nil,
            canInteractWithPage: url != nil,
            canInstallUserscript: url.map { UserScriptInstaller.isUserScriptURL($0) } ?? false)
        let menu = BrowserMenuViewController(state: menuState, delegate: self)
        present(menu.wrappedForPresentation(), animated: true)
    }

    /// Present the system Find-on-Page bar for the active tab (the find interaction is enabled at
    /// tab creation).
    private func presentFindOnPage() {
        installedWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Toggle a desktop user-agent on the active tab and reload, so a page renders its desktop site.
    private func toggleDesktopSite() {
        guard let webView = tabManager.activeTab?.webView else { return }
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.customUserAgent = (webView.customUserAgent == nil) ? desktopUA : nil
        webView.reload()
    }

    private func presentShare(for url: URL) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = toolbar
        present(share, animated: true)
    }

    private func presentDashboard(initialTab: BrownBearDashboardView.DashboardTab = .scripts) {
        present(BrownBearDashboardView.makeHostingController(initialTab: initialTab), animated: true)
    }

    private func presentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let alert = UIAlertController(title: "Couldn’t open", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - BrownBearTabGridControllerDelegate

extension BrownBearBrowserViewController: BrownBearTabGridControllerDelegate {
    func tabGrid(_ controller: BrownBearTabGridController, didSelect tab: Tab) {
        tabManager.setActiveTab(tab)
        controller.dismiss(animated: true)
    }

    func tabGridDidRequestNewTab(_ controller: BrownBearTabGridController) {
        let tab = tabManager.createTab()
        loadNewTabPage(in: tab)
        controller.dismiss(animated: true) { [weak self] in
            self?.refreshChrome()
            self?.omnibox.beginEditing()
        }
    }

    func tabGridDidRequestDismiss(_ controller: BrownBearTabGridController) {
        controller.dismiss(animated: true)
    }
}

// MARK: - WKNavigationDelegate (the exact lifecycle Module 2 hooks)

extension BrownBearBrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.show()
        progressBar.setProgress(0.05, animated: false)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The page's main document has started rendering — refresh the security indicator.
        if webView == installedWebView { refreshChrome() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressBar.complete()
        if webView == installedWebView { refreshChrome() }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.complete()
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.complete()
        // Ignore user-initiated cancellations (e.g. tapping a new link mid-load).
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            // Open external app schemes (mailto:, tel:, etc.) via the system.
            if let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "file", "data"].contains(scheme),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // One-tap userscript install: opening a *.user.js in the main frame shows the install
            // card instead of dumping raw JavaScript — the Tampermonkey/Greasemonkey behavior.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let scheme = url.scheme?.lowercased() ?? ""
            if isMainFrame,
               ["http", "https", "file"].contains(scheme),
               UserScriptInstaller.isUserScriptURL(url) {
                if viewSourceAllowOnce.remove(url) != nil {
                    decisionHandler(.allow)   // user picked "View source" — let it load as text
                    return
                }
                decisionHandler(.cancel)
                presentScriptInstall(for: url)
                return
            }
        }
        decisionHandler(.allow)
    }

    /// Present the install card for a userscript URL, with a "View source" escape that re-loads the
    /// raw file (allowed through the interceptor once).
    private func presentScriptInstall(for url: URL) {
        let installer = ScriptInstallViewController(
            url: url,
            onViewSource: { [weak self] sourceURL in
                guard let self else { return }
                self.viewSourceAllowOnce.insert(sourceURL)
                self.tabManager.activeTab?.load(sourceURL)
            })
        // Present on the top-most controller so the card still appears when a modal (the menu
        // action sheet, the dashboard) is already up — rather than silently swallowing the load.
        TopViewControllerPresenter.present(installer.wrappedForPresentation())
    }
}

// MARK: - WKUIDelegate (target="_blank" → new tab)

extension BrownBearBrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A target="_blank" link to a *.user.js (common on Greasy Fork / GitHub raw) must NOT spawn
        // a blank tab that then dumps raw JS — show the install card and open no window.
        if let url = navigationAction.request.url,
           ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
           UserScriptInstaller.isUserScriptURL(url) {
            presentScriptInstall(for: url)
            return nil
        }
        // A link asked to open in a new window/tab — honor it by creating a real new tab whose
        // web view is built from the exact configuration WebKit handed us.
        let tab = tabManager.createTab(adopting: configuration)
        tab.delegate = self
        return tab.webView
    }
}

// MARK: - ScriptBridgeHost (GM_openInTab)

extension BrownBearBrowserViewController: ScriptBridgeHost {
    func bridgeOpenInTab(url: URL, active: Bool) {
        let tab = tabManager.createTab(loading: url, activate: active)
        tab.delegate = self
        tab.loadPendingURLIfNeeded()
        if active { refreshChrome() }
    }
}

// MARK: - BrowserMenuDelegate (the rich "•••" menu)

extension BrownBearBrowserViewController: BrowserMenuDelegate {
    func browserMenu(_ menu: BrowserMenuViewController, didSelect action: BrowserMenuAction) {
        switch action {
        case .newTab:
            let tab = tabManager.createTab()
            loadNewTabPage(in: tab)
            refreshChrome()
            omnibox.beginEditing()
        case .reloadOrStop:
            guard let tab = tabManager.activeTab else { return }
            if tab.state.isLoading { tab.stopLoading() } else { tab.reload() }
        case .share:
            if let url = tabManager.activeTab?.state.url { presentShare(for: url) }
        case .copyLink:
            if let url = tabManager.activeTab?.state.url { UIPasteboard.general.url = url }
        case .findOnPage:
            presentFindOnPage()
        case .toggleDesktopSite:
            toggleDesktopSite()
        case .userscripts:
            presentDashboard(initialTab: .scripts)
        case .extensions:
            presentDashboard(initialTab: .extensions)
        case .installUserscript:
            if let url = tabManager.activeTab?.state.url { presentScriptInstall(for: url) }
        }
    }
}
