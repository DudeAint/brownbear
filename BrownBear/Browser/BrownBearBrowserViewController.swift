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
    // Not `private`: the chrome.cookies host logic lives in BrownBearBrowserViewController+Cookies.swift,
    // and a Swift extension in another file can only reach internal (or higher) members.
    lazy var configurationFactory = WebViewConfigurationFactory(injection: injection)
    // Not `private`: the page-zoom logic lives in BrownBearBrowserViewController+Zoom.swift, and a
    // Swift extension in another file can only reach internal (or higher) members.
    lazy var tabManager = TabManager(configurationFactory: configurationFactory)
    // Built per submit from the user's chosen search engine (AppSettings), so changing it in
    // Settings takes effect immediately.

    // MARK: - Chrome

    private let topChrome = UIView()
    // Not `private`: the omnibox delegate logic lives in BrownBearBrowserViewController+Omnibox.swift.
    let omnibox = OmniboxView()
    private let progressBar = ProgressBar()
    private let contentContainer = UIView()
    // Not `private`: the +Zoom extension (separate file) anchors the zoom HUD above this toolbar.
    let toolbar = BrowserToolbar()

    /// The web view currently installed in the content container.
    private weak var installedWebView: WKWebView?

    /// `*.user.js` URLs the user chose to view as raw source instead of installing — let through once.
    private var viewSourceAllowOnce: Set<URL> = []

    /// Live address-bar autocomplete shown while editing the omnibox (history + the typed action).
    /// Not `private`: the omnibox delegate logic lives in BrownBearBrowserViewController+Omnibox.swift.
    let omniboxSuggestions = OmniboxSuggestionsView()
    /// In-flight suggestion fetch, cancelled on each keystroke so stale results never overwrite newer.
    var suggestionTask: Task<Void, Never>?

    /// The transient page-zoom control and its live percentage label. Not `private`: driven by the
    /// +Zoom extension in a separate file (stored properties can't move to an extension).
    weak var zoomHUD: UIView?
    weak var zoomLabel: UILabel?

    /// The "Add to BrownBear" banner shown on a Chrome Web Store detail page. Not `private`: built in
    /// BrownBearBrowserViewController+ExtensionInstall.swift (its extension id rides on the view's
    /// accessibilityIdentifier so we don't rebuild it on every navigation tick for the same page).
    weak var extensionInstallBanner: UIView?

    /// Drives the tab grid's spring zoom open/close. Retained here because UIKit holds a
    /// `transitioningDelegate` only weakly.
    private let tabGridTransition = TabGridTransitionController()

    /// Maps Tab UUIDs to the stable integer ids chrome.tabs exposes. Owned here, used by the
    /// WebExtensionBridgeHost conformance in BrownBearBrowserViewController+WebExtensions.swift.
    let webExtTabRegistry = WebExtensionTabRegistry()
    /// Turns the tab + navigation lifecycle into chrome.tabs.* / chrome.webNavigation.* events for
    /// extension workers and popups. Fed from the TabManager + WKNavigation delegate hooks below.
    private lazy var webExtEvents = WebExtensionEventEmitter(registry: webExtTabRegistry, host: self)
    /// Last-seen tab id set, so tabManager(_:didUpdate:) can diff to fire tabs.onCreated / onRemoved.
    private var lastKnownTabIDs: [UUID] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
        tabManager.delegate = self
        omnibox.delegate = self
        toolbar.delegate = self
        injection.bridgeHost = self
        injection.webExtensionBridgeHost = self   // chrome.tabs → TabManager
        injection.webExtensionCookieHost = self   // chrome.cookies → WKHTTPCookieStore
        webExtEvents.setHost(self)   // chrome.tabs/webNavigation event push uses the tab registry
        DownloadManager.shared.onDownloadStarted = { [weak self] in self?.presentDownloadStartedToast() }
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

        // Suggestions overlay the page between the bar and the toolbar; added last so it sits on top.
        omniboxSuggestions.delegate = self
        omniboxSuggestions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(omniboxSuggestions)

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
                                         constant: -BrownBearTheme.Metrics.toolbarHeight),

            omniboxSuggestions.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            omniboxSuggestions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            omniboxSuggestions.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            omniboxSuggestions.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
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

        // Fade the newly-installed web view in so switching tabs (and opening a new one) crossfades
        // rather than snapping.
        webView.alpha = 0
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            webView.alpha = 1
        }

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
        applyPrivateChrome()
    }

    /// Tint the top chrome a distinct dark shade when the active tab is private, so the user can tell
    /// at a glance they're in a private session (the Safari/Firefox private-bar cue). Forcing the
    /// chrome subtree to dark appearance makes the omnibox text/icons resolve to their light variants,
    /// so they stay readable on the dark private bar even when the app is in light mode.
    private func applyPrivateChrome() {
        let isPrivate = tabManager.activeTab?.isPrivate ?? false
        topChrome.backgroundColor = isPrivate
            ? UIColor(red: 0.11, green: 0.09, blue: 0.16, alpha: 1)
            : BrownBearTheme.Palette.chrome
        topChrome.overrideUserInterfaceStyle = isPrivate ? .dark : .unspecified
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

    // Not `private`: also used by the WebExtensionBridgeHost conformance for chrome.tabs.create({}).
    func loadNewTabPage(in tab: Tab) {
        tab.delegate = self
        // Private tabs get a distinct incognito page (no shortcut tiles, explicit "not saved" copy);
        // normal tabs build from the user's bookmarks (a fast actor read).
        if tab.isPrivate {
            tab.webView.loadHTMLString(Self.privateNewTabHTML(), baseURL: nil)
            return
        }
        Task { @MainActor in
            let bookmarks = await BrownBearServices.shared.bookmarkStore.all()
            tab.webView.loadHTMLString(Self.newTabHTML(bookmarks: bookmarks), baseURL: nil)
        }
    }

    /// Suggested shortcut tiles shown when the user has no bookmarks yet.
    private static let suggestedSites: [(title: String, url: String, host: String)] = [
        ("Google", "https://www.google.com/", "www.google.com"),
        ("YouTube", "https://www.youtube.com/", "www.youtube.com"),
        ("Wikipedia", "https://www.wikipedia.org/", "www.wikipedia.org"),
        ("GitHub", "https://github.com/", "github.com"),
        ("Reddit", "https://www.reddit.com/", "www.reddit.com"),
        ("GreasyFork", "https://greasyfork.org/", "greasyfork.org"),
        ("Hacker News", "https://news.ycombinator.com/", "news.ycombinator.com"),
        ("DuckDuckGo", "https://duckduckgo.com/", "duckduckgo.com")
    ]

    private static func htmlEscape(_ string: String) -> String {
        var out = string.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    /// A branded New Tab page: a search box plus shortcut tiles (the user's bookmarks, or suggested
    /// sites when there are none). Tiles are plain `<a>` links and the search box is a plain `<form>`,
    /// so both navigate through the normal load flow — no privileged bridge. First-party content; bookmark
    /// titles/URLs are HTML-escaped and limited to http(s) before injection (the page runs untrusted-
    /// adjacent, so we never inject raw user strings).
    private static func newTabHTML(bookmarks: [Bookmark]) -> String {
        let web = bookmarks.filter { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
        let entries: [(title: String, url: String, host: String)] = web.isEmpty
            ? suggestedSites
            : web.prefix(12).map { (title: $0.displayTitle, url: $0.url.absoluteString, host: $0.url.host ?? "") }
        let engine = AppSettings.searchEngine

        let tiles = entries.map { entry -> String in
            let title = htmlEscape(entry.title)
            let url = htmlEscape(entry.url)
            let host = htmlEscape(entry.host)
            let letter = htmlEscape((entry.title.first.map { String($0).uppercased() }) ?? "•")
            return """
            <a class="tile" href="\(url)">
            <span class="ico"><img src="https://\(host)/favicon.ico" onload="this.style.opacity=1" onerror="this.remove()" alt="">
            <span class="mono">\(letter)</span></span>
            <span class="lbl">\(title)</span></a>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
          :root{color-scheme:light dark;
            --bg:#F7F5F2;--field:#EFEAE4;--text:#1A140E;--sub:#6B6058;--accent:#E0832F;--border:#E2DBD2;}
          @media (prefers-color-scheme:dark){:root{
            --bg:#14110E;--field:#2A231C;--text:#F5EFE7;--sub:#B6A99C;--accent:#FFB454;--border:#322A22;}}
          *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
          html,body{margin:0;height:100%;font-family:-apple-system,system-ui,sans-serif;
            background:var(--bg);color:var(--text);}
          .wrap{max-width:680px;margin:0 auto;padding:max(40px,8vh) 20px 40px;}
          .brand{display:flex;align-items:center;gap:10px;justify-content:center;margin-bottom:26px;}
          .brand .bear{font-size:30px;}
          .brand h1{font-size:22px;font-weight:800;margin:0;letter-spacing:-.4px;}
          .brand h1 b{color:var(--accent);font-weight:800;}
          form.search{display:flex;align-items:center;gap:10px;background:var(--field);
            border:1px solid var(--border);border-radius:16px;padding:0 14px;height:52px;
            margin-bottom:30px;box-shadow:0 4px 16px rgba(0,0,0,.06);}
          form.search svg{width:20px;height:20px;fill:var(--sub);flex:none;}
          form.search input{flex:1;border:0;background:transparent;font-size:17px;color:var(--text);outline:none;}
          .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;}
          .tile{display:flex;flex-direction:column;align-items:center;gap:8px;
            text-decoration:none;color:var(--text);}
          .ico{position:relative;width:60px;height:60px;border-radius:16px;background:var(--accent);
            display:grid;place-items:center;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.10);}
          .ico img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;
            padding:12px;background:#fff;opacity:0;transition:opacity .12s ease;}
          .ico .mono{font-size:26px;font-weight:700;color:#fff;}
          .lbl{font-size:12px;font-weight:500;max-width:72px;white-space:nowrap;overflow:hidden;
            text-overflow:ellipsis;text-align:center;}
          @media (max-width:380px){.grid{grid-template-columns:repeat(3,1fr);}}
        </style></head><body>
          <div class="wrap">
            <div class="brand"><span class="bear">🐻</span><h1>Brown<b>Bear</b></h1></div>
            <form class="search" action="\(engine.formAction)" method="GET" autocomplete="off">
              <svg viewBox="0 0 24 24"><path d="M21 20l-5.6-5.6a7 7 0 10-1.4 1.4L20 21zM5 10a5 5 0 1110 0 5 5 0 01-10 0z"/></svg>
              <input name="\(engine.formQueryParam)" placeholder="Search \(engine.title)" autocapitalize="off" autocorrect="off" spellcheck="false">
            </form>
            <div class="grid">
        \(tiles)
            </div>
          </div>
        </body></html>
        """
    }

    /// The private/incognito New Tab page: a dark, self-explanatory page that makes clear nothing is
    /// being saved. No shortcut tiles (which would leak browsing) — just the search box and the
    /// privacy explanation, matching Safari/Chrome incognito. First-party, no user strings injected.
    private static func privateNewTabHTML() -> String {
        let engine = AppSettings.searchEngine
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
          :root{color-scheme:dark;--bg:#161020;--field:#241a33;--text:#F3EEFA;--sub:#A99CC2;
            --accent:#B79CF0;--border:#33264a;}
          *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
          html,body{margin:0;height:100%;font-family:-apple-system,system-ui,sans-serif;
            background:var(--bg);color:var(--text);}
          .wrap{max-width:560px;margin:0 auto;padding:max(48px,10vh) 24px 40px;text-align:center;}
          .glyph{font-size:40px;margin-bottom:14px;}
          h1{font-size:22px;font-weight:800;margin:0 0 10px;letter-spacing:-.3px;}
          p{font-size:15px;line-height:1.5;color:var(--sub);margin:0 auto 28px;max-width:420px;}
          form.search{display:flex;align-items:center;gap:10px;background:var(--field);
            border:1px solid var(--border);border-radius:16px;padding:0 14px;height:52px;text-align:left;}
          form.search svg{width:20px;height:20px;fill:var(--sub);flex:none;}
          form.search input{flex:1;border:0;background:transparent;font-size:17px;color:var(--text);outline:none;}
        </style></head><body>
          <div class="wrap">
            <div class="glyph">🕶️</div>
            <h1>Private Browsing</h1>
            <p>Pages you view in private tabs won't appear in your history, and cookies and site
               data are cleared when you close them. Downloads and bookmarks you save are kept.</p>
            <form class="search" action="\(engine.formAction)" method="GET" autocomplete="off">
              <svg viewBox="0 0 24 24"><path d="M21 20l-5.6-5.6a7 7 0 10-1.4 1.4L20 21zM5 10a5 5 0 1110 0 5 5 0 01-10 0z"/></svg>
              <input name="\(engine.formQueryParam)" placeholder="Search privately" autocapitalize="off" autocorrect="off" spellcheck="false">
            </form>
          </div>
        </body></html>
        """
    }
}

// MARK: - TabManagerDelegate

extension BrownBearBrowserViewController: TabManagerDelegate {
    func tabManager(_ manager: TabManager, didUpdate tabs: [Tab]) {
        toolbar.update(canGoBack: tabManager.activeTab?.state.canGoBack ?? false,
                       canGoForward: tabManager.activeTab?.state.canGoForward ?? false,
                       tabCount: tabs.count)
        // Diff the tab set to fire chrome.tabs.onCreated / onRemoved. Resolve a removed tab's id
        // BEFORE forgetting its registry mapping so onRemoved carries the right id.
        let known = Set(lastKnownTabIDs)
        let current = Set(tabs.map(\.id))
        for tab in tabs where !known.contains(tab.id) {
            webExtEvents.tabCreated(webExtTabRecord(tab))
        }
        for removedID in lastKnownTabIDs where !current.contains(removedID) {
            webExtEvents.tabRemoved(extTabId: webExtTabRegistry.id(for: removedID))
            webExtTabRegistry.forget(uuid: removedID)
        }
        lastKnownTabIDs = tabs.map(\.id)
    }

    func tabManager(_ manager: TabManager, didActivate tab: Tab?, previous: Tab?) {
        previous?.refreshSnapshot()
        installActiveWebView()
        refreshChrome()
        if let tab {
            webExtEvents.tabActivated(extTabId: webExtTabRegistry.id(for: tab.id))
        }
        // If the user closed the last tab, open a fresh New Tab page.
        if tab == nil {
            openInitialTabIfNeeded()
        }
    }
}

// MARK: - TabDelegate

extension BrownBearBrowserViewController: TabDelegate {
    func tab(_ tab: Tab, didChange state: NavigationState) {
        // chrome.tabs.onUpdated fires for EVERY tab (Chrome parity), so emit before the active-tab
        // guard. The emitter diffs against the last record and only fires on a real change.
        webExtEvents.tabUpdated(webExtTabRecord(tab))
        guard tab.id == tabManager.activeTabID else { return }
        omnibox.update(with: state)
        toolbar.update(canGoBack: state.canGoBack,
                       canGoForward: state.canGoForward,
                       tabCount: tabManager.count)
        syncProgress(for: state)
        // Catches the Chrome Web Store's in-page (SPA) navigation between extensions, not just full
        // loads, so the "Add to BrownBear" banner tracks the URL even when didFinish doesn't fire.
        updateExtensionInstallBanner(url: state.url)
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

    func toolbarDidLongPressBack(_ toolbar: BrowserToolbar) { presentBackForwardList(forward: false) }
    func toolbarDidLongPressForward(_ toolbar: BrowserToolbar) { presentBackForwardList(forward: true) }

    func toolbarDidLongPressNewTab(_ toolbar: BrowserToolbar) {
        let tab = tabManager.createTab(isPrivate: true)
        loadNewTabPage(in: tab)
        refreshChrome()
        omnibox.beginEditing()
    }

    /// Present the active tab's back/forward history as a list (the Chrome/Safari long-press menu),
    /// so a user 8 pages deep can jump straight to page 2 instead of tapping back six times.
    private func presentBackForwardList(forward: Bool) {
        guard let tab = tabManager.activeTab else { return }
        let items = forward
            ? tab.webView.backForwardList.forwardList
            : Array(tab.webView.backForwardList.backList.reversed())
        guard !items.isEmpty else { return }
        let sheet = UIAlertController(title: forward ? "Forward" : "Back", message: nil, preferredStyle: .actionSheet)
        for item in items.prefix(12) {
            let title = (item.title?.isEmpty == false ? item.title : nil) ?? item.url.host ?? item.url.absoluteString
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak tab] _ in
                tab?.webView.go(to: item)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = toolbar
        sheet.popoverPresentationController?.sourceRect = toolbar.bounds
        present(sheet, animated: true)
    }

    private func presentTabGrid() {
        let grid = BrownBearTabGridController(tabManager: tabManager,
                                             showingPrivate: tabManager.activeTab?.isPrivate ?? false)
        grid.gridDelegate = self
        grid.modalPresentationStyle = .fullScreen
        grid.transitioningDelegate = tabGridTransition   // spring zoom open/close
        present(grid, animated: true)
    }

    private func presentMenu() {
        let tab = tabManager.activeTab
        let state = tab?.state ?? NavigationState()
        let url = state.url
        let isDesktop = tab?.prefersDesktop ?? false
        // The bookmarked check is async (actor); build + present the menu once it resolves.
        Task { @MainActor in
            let isBookmarked: Bool
            if let url {
                isBookmarked = await BrownBearServices.shared.bookmarkStore.contains(url: url)
            } else {
                isBookmarked = false
            }
            var matchedScripts: [MenuScript] = []
            if let url {
                let urlString = url.absoluteString
                matchedScripts = await BrownBearServices.shared.scriptStore.all()
                    .filter { $0.metadata.hasMatchingDirective && URLMatcher(metadata: $0.metadata).matches(urlString) }
                    .prefix(6)
                    .map { MenuScript(id: $0.id, name: $0.metadata.displayName,
                                      iconURL: $0.metadata.iconURL, enabled: $0.enabled) }
            }
            // Surface each enabled extension's chrome.action as a menu row (iOS has no toolbar). The
            // action state is registered + resolved for the active tab so the badge/title reflect what
            // the extension set; disabled actions are skipped.
            var extensionActions: [MenuExtensionAction] = []
            let actionState = BrownBearServices.shared.webExtensionActionState
            let actionTabId = webExtActionActiveTabId()
            for ext in await BrownBearServices.shared.webExtensionStore.enabledExtensions() {
                guard let action = ext.manifest?.action else { continue }
                actionState.registerManifestAction(extensionID: ext.id, action: action)
                let resolved = actionState.resolved(extensionID: ext.id, tabId: actionTabId)
                guard resolved.enabled else { continue }
                extensionActions.append(MenuExtensionAction(
                    extensionID: ext.id,
                    title: resolved.title.isEmpty ? ext.displayName : resolved.title,
                    badgeText: resolved.badgeText,
                    badgeColor: Self.actionBadgeColor(actionState.badgeColorBytes(extensionID: ext.id, tabId: actionTabId)),
                    iconPath: resolved.iconPath,
                    hasPopup: (action.defaultPopup?.isEmpty == false),
                    hasOptions: (ext.manifest?.optionsPage?.isEmpty == false)))
            }
            // GM_registerMenuCommand entries the matching userscripts registered for THIS tab's web
            // view (iframe registrations included). Built from the active tab's live injections.
            var scriptCommands: [MenuScriptCommand] = []
            if let activeWebView = tabManager.activeTab?.webView {
                scriptCommands = injection.userScriptMenuCommands(in: activeWebView).map {
                    MenuScriptCommand(token: $0.token,
                                      commandID: $0.commandID,
                                      title: $0.title,
                                      scriptName: $0.scriptName,
                                      accessKey: $0.accessKey,
                                      autoClose: $0.autoClose)
                }
            }
            let menuState = BrowserMenuState(
                title: state.title,
                host: state.displayHost,
                isLoading: state.isLoading,
                isDesktopSite: isDesktop,
                canInteractWithPage: url != nil,
                canInstallUserscript: url.map { UserScriptInstaller.isUserScriptURL($0) } ?? false,
                isBookmarked: isBookmarked,
                zoomPercent: Int(((tab?.webView.pageZoom ?? 1.0) * 100).rounded()),
                matchedScripts: matchedScripts,
                extensionActions: extensionActions,
                scriptCommands: scriptCommands)
            // The actor hop above defers this present to a later turn; don't stack a second menu if
            // a rapid double-tap already presented one.
            guard presentedViewController == nil else { return }
            let menu = BrowserMenuViewController(state: menuState, delegate: self)
            present(menu.wrappedForPresentation(), animated: true)
        }
    }

    /// Present the system Find-on-Page bar for the active tab (the find interaction is enabled at
    /// tab creation).
    private func presentFindOnPage() {
        installedWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Toggle a desktop user-agent on the active tab and reload, so a page renders its desktop site.
    private func toggleDesktopSite() {
        guard let tab = tabManager.activeTab else { return }
        tab.prefersDesktop.toggle()
        let webView = tab.webView
        // Set BOTH levers: a desktop UA for sites that sniff it, and (the reliable one) the
        // per-navigation preferredContentMode applied in decidePolicyFor below. Then re-load the URL
        // so the new mode actually takes effect (reload() can serve cache and skip re-requesting).
        webView.customUserAgent = tab.prefersDesktop ? Self.desktopSafariUserAgent : nil
        if let url = webView.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reloadFromOrigin()
        }
    }

    private func presentShare(for url: URL) {
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = toolbar
        present(share, animated: true)
    }

    private func presentDashboard(initialTab: BrownBearDashboardView.DashboardTab = .scripts) {
        present(BrownBearDashboardView.makeHostingController(initialTab: initialTab), animated: true)
    }

    private func toggleBookmarkForActiveTab() {
        guard let tab = tabManager.activeTab, let url = tab.state.url else { return }
        let title = tab.state.displayTitle
        Task { await BrownBearServices.shared.bookmarkStore.toggle(title: title, url: url) }
    }

    private func presentBookmarks() {
        present(BookmarksView.makeHostingController(onOpen: { [weak self] url in
            self?.openBookmark(url)
        }), animated: true)
    }

    private func presentHistory() {
        present(HistoryView.makeHostingController(onOpen: { [weak self] url in
            self?.openBookmark(url)
        }), animated: true)
    }

    private func openBookmark(_ url: URL) {
        let tab = tabManager.createTab(loading: url)
        tab.delegate = self
        tab.loadPendingURLIfNeeded()
        refreshChrome()
    }

    // Not `private`: also called from the omnibox delegate in BrownBearBrowserViewController+Omnibox.
    func presentError(_ error: Error) {
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

    func tabGrid(_ controller: BrownBearTabGridController, didRequestNewTabPrivate isPrivate: Bool) {
        let tab = tabManager.createTab(isPrivate: isPrivate)
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
        if let id = extTabId(for: webView) {
            webExtEvents.webNavBeforeNavigate(extTabId: id, url: webView.url?.absoluteString ?? "")
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The page's main document has started rendering — refresh the security indicator.
        if webView == installedWebView { refreshChrome() }
        applyStoredZoom(for: webView)
        if let id = extTabId(for: webView) {
            webExtEvents.webNavCommitted(extTabId: id, url: webView.url?.absoluteString ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressBar.complete()
        if webView == installedWebView { refreshChrome() }
        recordHistory(for: webView)
        // WKWebView gives no separate DOMContentLoaded; fire both at didFinish (DOMContentLoaded first),
        // which is the common shim behavior — documented in docs/WEB_EXTENSIONS.md.
        if let id = extTabId(for: webView) {
            let url = webView.url?.absoluteString ?? ""
            webExtEvents.webNavDOMContentLoaded(extTabId: id, url: url)
            webExtEvents.webNavCompleted(extTabId: id, url: url)
        }
    }

    /// The chrome tab id for the tab backing `webView`, or nil if none — for webNavigation events.
    private func extTabId(for webView: WKWebView) -> Int? {
        tabManager.tabs.first { $0.webView === webView }.map { webExtTabRegistry.id(for: $0.id) }
    }

    /// Record a finished main-frame navigation in browsing history. Only real web pages are kept —
    /// about:blank (the New Tab page), data:, and file: URLs are skipped, as are app schemes (which
    /// never reach didFinish here). Private tabs are never recorded.
    private func recordHistory(for webView: WKWebView) {
        // Skip private tabs — an incognito session must leave no history trace.
        if let tab = tabManager.tabs.first(where: { $0.webView === webView }), tab.isPrivate { return }
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let title = webView.title
        Task { await BrownBearServices.shared.historyStore.record(url: url, title: title) }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.complete()
        if let id = extTabId(for: webView) {
            webExtEvents.webNavErrorOccurred(extTabId: id, url: webView.url?.absoluteString ?? "",
                                             error: (error as NSError).localizedDescription)
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.complete()
        // Ignore user-initiated cancellations (e.g. tapping a new link mid-load).
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        if let id = extTabId(for: webView) {
            webExtEvents.webNavErrorOccurred(extTabId: id, url: webView.url?.absoluteString ?? "",
                                             error: nsError.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // Apply the tab's desktop/mobile choice to every navigation. preferredContentMode is the
        // reliable lever (a desktop UA alone is ignored by responsive sites), so the Desktop toggle
        // actually changes the rendered layout — and it persists across the tab's loads.
        let destination = navigationAction.request.url
        let isStore = destination.map(Self.isChromeWebStoreURL) ?? false
        if let tab = tabManager.tabs.first(where: { $0.webView === webView }) {
            // Chrome Web Store pages only render their real "Add to Chrome" button (and skip the
            // "you're not on Chrome" banner) for a desktop Chrome client, so force that for store
            // hosts regardless of the tab's toggle; otherwise honor the user's Desktop choice.
            if isStore {
                preferences.preferredContentMode = .desktop
                webView.customUserAgent = Self.desktopChromeUserAgent
            } else {
                preferences.preferredContentMode = tab.prefersDesktop ? .desktop : .mobile
                // Clear the store UA when leaving the store (but don't clobber a manual Desktop UA).
                if webView.customUserAgent == Self.desktopChromeUserAgent {
                    webView.customUserAgent = tab.prefersDesktop ? Self.desktopSafariUserAgent : nil
                }
            }
            applyShields(to: tab, preferences: preferences, navigationAction: navigationAction, destination: destination, isStore: isStore)
        }
        if let url = navigationAction.request.url {
            // Open external app schemes (mailto:, tel:, etc.) via the system.
            if let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "file", "data"].contains(scheme),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel, preferences)
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
                    decisionHandler(.allow, preferences)   // user picked "View source" — load as text
                    return
                }
                decisionHandler(.cancel, preferences)
                presentScriptInstall(for: url)
                return
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // If WebKit can't render this response inline (a PDF, zip, dmg, or any binary asset), turn it
        // into a download instead of showing a blank page. Userscript *.user.js installs are already
        // intercepted in navigationAction, so they never reach here.
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        // begin() sets the delegate; the manager asks the user to confirm before any bytes are
        // written, and fires onDownloadStarted (→ the toast) only once a download actually begins.
        DownloadManager.shared.begin(download)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.begin(download)
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
        // web view is built from the exact configuration WebKit handed us. A popup opened from a
        // private tab must stay private, so inherit the opener's privacy.
        let openerIsPrivate = tabManager.activeTab?.isPrivate ?? false
        let tab = tabManager.createTab(adopting: configuration, isPrivate: openerIsPrivate)
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

    func bridgeTabId(for webView: WKWebView) -> Int? {
        // Resolve off the SAME registry chrome.tabs uses, so a userscript's GM_getTab and an extension's
        // chrome.tabs.get agree on this tab's id. nil when no tab owns the web view (headless/closing).
        tabManager.tabs.first { $0.webView === webView }.map { webExtTabRegistry.id(for: $0.id) }
    }

    func bridgeMenuCommandsDidChange(in webView: WKWebView) {
        // If the "•••" menu is open on the active tab, rebuild it so a just-(un)registered command shows
        // up / disappears live. Otherwise nothing to do — the menu reads commands fresh on next present.
        guard webView === tabManager.activeTab?.webView,
              let menu = presentedViewController as? BrowserMenuViewController else { return }
        rebuildOpenMenu(replacing: menu)
    }
}

// MARK: - BrowserMenuDelegate (the rich "•••" menu)

extension BrownBearBrowserViewController: BrowserMenuDelegate {
    func browserMenu(_ menu: BrowserMenuViewController, didSelect action: BrowserMenuAction) {
        switch action {
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
        case .toggleBookmark:
            toggleBookmarkForActiveTab()
        case .bookmarks:
            presentBookmarks()
        case .history:
            presentHistory()
        case .downloads:
            presentDownloads()
        case .settings:
            presentDashboard(initialTab: .settings)
        case .reader:
            presentReader()
        case .zoom:
            presentZoomHUD()
        }
    }

    func browserMenu(_ menu: BrowserMenuViewController, didToggleScript id: UUID, enabled: Bool) {
        // Persist the toggle; re-injection happens on the next navigation (no hot re-inject), which
        // matches the engine's existing behavior.
        Task { await BrownBearServices.shared.scriptStore.setEnabled(id: id, enabled) }
    }

    func browserMenu(_ menu: BrowserMenuViewController, didTapExtensionAction extensionID: String) {
        // The menu already dismissed itself; open the extension's popup or fire chrome.action.onClicked.
        webExtTriggerAction(extensionID: extensionID)
    }

    func browserMenu(_ menu: BrowserMenuViewController, didTapScriptCommand command: MenuScriptCommand) {
        // The menu either already dismissed (autoClose) or stayed open; fire the script's callback back
        // into its own frame/world. Stale rows (the script unregistered or navigated) fire nothing.
        injection.fireUserScriptMenuCommand(token: command.token, commandID: command.commandID)
    }

    func browserMenu(_ menu: BrowserMenuViewController, didRequestExtensionOptions extensionID: String) {
        // The menu already dismissed; open the extension's options page (sheet or tab per open_in_tab).
        webExtOpenOptionsPage(extensionID: extensionID)
    }
}

extension BrownBearBrowserViewController {
    /// Dismiss an open "•••" menu and re-present it so a live GM_registerMenuCommand change is reflected.
    /// presentMenu() guards against double-presenting, so the re-present is safe after dismissal.
    fileprivate func rebuildOpenMenu(replacing menu: BrowserMenuViewController) {
        menu.dismiss(animated: false) { [weak self] in
            self?.presentMenu()
        }
    }
}

// MARK: - Hardware keyboard shortcuts (iPad / Magic Keyboard)

extension BrownBearBrowserViewController {

    override var canBecomeFirstResponder: Bool { true }

    /// The standard browser shortcut set, so BrownBear is usable as an iPad daily driver. Mapped to
    /// the same actions the chrome buttons invoke.
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "New Tab", action: #selector(keyNewTab), input: "t", modifierFlags: .command),
            UIKeyCommand(title: "New Private Tab", action: #selector(keyNewPrivateTab),
                         input: "n", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Close Tab", action: #selector(keyCloseTab), input: "w", modifierFlags: .command),
            UIKeyCommand(title: "Focus Address Bar", action: #selector(keyFocusOmnibox),
                         input: "l", modifierFlags: .command),
            UIKeyCommand(title: "Reload", action: #selector(keyReload), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "Find on Page", action: #selector(keyFind), input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Show Tabs", action: #selector(keyShowTabs), input: "\\", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Back", action: #selector(keyBack), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "Forward", action: #selector(keyForward), input: "]", modifierFlags: .command)
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func keyNewTab() { toolbarDidTapNewTab(toolbar) }
    @objc private func keyNewPrivateTab() { toolbarDidLongPressNewTab(toolbar) }
    @objc private func keyCloseTab() { if let id = tabManager.activeTabID { tabManager.closeTab(id: id) } }
    @objc private func keyFocusOmnibox() { omnibox.beginEditing() }
    @objc private func keyReload() { tabManager.activeTab?.reload() }
    @objc private func keyFind() { presentFindOnPage() }
    @objc private func keyShowTabs() { toolbarDidTapTabs(toolbar) }
    @objc private func keyBack() { tabManager.activeTab?.goBack() }
    @objc private func keyForward() { tabManager.activeTab?.goForward() }
}
