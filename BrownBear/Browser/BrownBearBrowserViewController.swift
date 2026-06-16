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

    // Not `private`: the chrome layout + scroll-hide logic live in BrownBearBrowserViewController
    // +Layout.swift / +ScrollChrome.swift (separate files can only reach internal-or-higher members).
    let topChrome = UIView()
    // Not `private`: the omnibox delegate logic lives in BrownBearBrowserViewController+Omnibox.swift.
    let omnibox = OmniboxView()
    let progressBar = ProgressBar()
    let contentContainer = UIView()
    /// Horizontal swipe on the address bar to slide to the adjacent tab, Safari-style. Wired and driven
    /// in BrownBearBrowserViewController+TabSwipe.swift; `tabSwipeSession` holds the in-flight overlay.
    let tabSwipePan = UIPanGestureRecognizer()
    var tabSwipeSession: TabSwipeSession?
    // Not `private`: the +Zoom extension (separate file) anchors the zoom HUD above this toolbar.
    let toolbar = BrowserToolbar()
    /// Bottom-mode only: when the bottom bar hides on scroll, this chrome-coloured strip stays put above
    /// the home indicator showing just the site's domain (Safari-style), so the bar doesn't vanish into
    /// the home-indicator area and you still know where you are. Tapping it brings the full bar back.
    /// Built in +Layout, shown/hidden in +ScrollChrome, its host text refreshed in refreshChrome.
    let collapsedBottomBar = UIView()
    let collapsedHostLabel = UILabel()
    /// The SSL lock / insecure-warning glyph shown to the LEFT of the domain in the collapsed strip,
    /// mirroring the omnibox's leading security glyph (lock.fill when secure, warning triangle when not).
    let collapsedLockGlyph = UIImageView()
    /// Lock + domain in one horizontal group, so +ScrollChrome can slide the whole identity DOWN into
    /// place as the bar collapses (rather than the domain just popping in).
    let collapsedHostStack = UIStackView()

    /// The top-chrome's HEIGHT constraint, whose constant the scroll-hide animation drives: full
    /// (safe-area + omnibox) when shown, collapsed to just the safe-area inset when hidden — so the bar
    /// rolls up but the status-bar / Dynamic Island strip stays chrome-coloured and the page never
    /// slides under it. Built in +Layout, animated in +ScrollChrome.
    var topChromeHeightConstraint: NSLayoutConstraint?
    /// The omnibox's `top == topChrome.top + offset` constraint. The omnibox is pinned to topChrome (not
    /// the view's safe area) so the whole bar moves as one unit; the offset is the safe-area-top + 8 in
    /// top mode (status bar above it) or 8 in bottom mode, tracked in viewSafeAreaInsetsDidChange.
    var omniboxTopConstraint: NSLayoutConstraint?
    /// Bottom mode only: the toolbar's `bottom == safeArea.bottom + c` constraint. Scroll-hide drives `c`
    /// to slide the whole bottom chrome (omnibox + toolbar) down off-screen, and back to 0 to restore.
    var bottomChromeBottomConstraint: NSLayoutConstraint?
    /// The two position-specific constraint sets (top-bar vs bottom-bar); exactly one is active.
    /// applyAddressBarPosition swaps them when the preference changes. Built in +Layout.
    var topPositionConstraints: [NSLayoutConstraint] = []
    var bottomPositionConstraints: [NSLayoutConstraint] = []
    /// Observes `.brownBearChromeLayoutChanged` so a Settings change re-lays-out the chrome live.
    var chromeLayoutObserver: NSObjectProtocol?
    /// Observes `.brownBearOpenURL` so a presented surface (e.g. the dashboard's store links) can open a
    /// URL in a new tab without holding a reference to this controller.
    var openURLObserver: NSObjectProtocol?
    /// Observe extension install/enable/remove and the toolbar pin-pref change, to re-evaluate the pinned
    /// extensions button. Managed in BrownBearBrowserViewController+ExtensionsToolbar.swift.
    var extensionsChangeObserver: NSObjectProtocol?
    var extensionsToolbarPrefObserver: NSObjectProtocol?
    /// App-foreground observer so the toolbar extensions icon re-shows after a cold relaunch (the
    /// viewDidLoad refresh can race the extension store's first load). Managed in +ExtensionsToolbar.
    var extensionsToolbarActiveObserver: NSObjectProtocol?
    /// The enabled extensions (with a chrome.action) the toolbar icon stands for, cached so a tap can act
    /// without re-fetching: one → open its popup, several → the list popover.
    var pinnedExtensionItems: [ExtensionListItem] = []
    /// Observes keyboard-frame changes so the BOTTOM address bar lifts above the keyboard while editing.
    var keyboardObserver: NSObjectProtocol?
    /// True while the keyboard is up — scroll-hide is suspended so typing doesn't fight the lift.
    var keyboardVisible = false
    /// How far the bottom chrome is currently lifted above the keyboard (0 when not editing). Tracked so
    /// a re-layout (rotation / safe-area change) preserves the lift instead of dropping the bar behind it.
    var keyboardLiftOverlap: CGFloat = 0
    /// Whether the chrome is currently slid away (scrolled down). Drives idempotent show/hide.
    var chromeHidden = false
    /// The scroll offset at the last direction sample, so +ScrollChrome can detect up vs. down.
    var lastScrollOffsetY: CGFloat = 0
    /// The deepest top-overscroll reached during the CURRENT drag, so pull-to-refresh only fires on a
    /// deliberate downward pull (reset at drag start in +ScrollChrome).
    var pullMaxOverscroll: CGFloat = 0

    /// The web view currently installed in the content container.
    /// Internal so the WKNavigationDelegate companion file (BrownBearBrowserViewController+Navigation)
    /// can read it; it stays effectively controller-private (only the controller's own files touch it).
    weak var installedWebView: WKWebView?

    /// `*.user.js` URLs the user chose to view as raw source instead of installing — let through once.
    /// Internal for the +Navigation companion file (same controller-private intent).
    var viewSourceAllowOnce: Set<URL> = []

    /// The in-page translation bar (Translate menu action), shown while the active page is translated.
    /// Managed in BrownBearBrowserViewController+Translate.swift; held so it can be replaced/dismissed.
    var translateBar: TranslateBar?

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
    lazy var webExtEvents = WebExtensionEventEmitter(registry: webExtTabRegistry, host: self)
    /// Last-seen tab id set, so tabManager(_:didUpdate:) can diff to fire tabs.onCreated / onRemoved.
    private var lastKnownTabIDs: [UUID] = []
    /// The TARGET url of each web view's in-flight main-frame navigation, captured at policy-decision
    /// time (navigationAction.request.url) so webNavigation.onBeforeNavigate can report where the
    /// navigation is GOING. `webView.url` still holds the PREVIOUS committed page until didCommit, so
    /// reading it at didStartProvisionalNavigation reported the wrong (old) URL. Consumed once per
    /// navigation start; bounded (one entry per web view, cleared on consume / failure). Internal for
    /// the +Navigation companion file that records/consumes it.
    var pendingNavTargets: [ObjectIdentifier: String] = [:]

    /// Consecutive declarativeNetRequest main-frame redirects per web view, to break a redirect loop
    /// (e.g. two rules that bounce A→B→A). Bumped each time the nav delegate diverts a navigation; reset
    /// to 0 once a page actually commits. Internal for the +Navigation companion file.
    var extensionRedirectDepth: [ObjectIdentifier: Int] = [:]

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
        injection.historyStateHandler.delegate = self   // SPA history → webNavigation.onHistoryStateUpdated
        DownloadManager.shared.onDownloadStarted = { [weak self] in self?.presentDownloadStartedToast() }
        buildHierarchy()
        installTabSwipeGesture()
        registerChromeLayoutObservers()
        registerExtensionsToolbarObservers()
        startTabSessionPersistence()   // save open tabs on background so they survive app close
        refreshExtensionsToolbarIcon()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Re-evaluate the toolbar extensions icon once the view is fully on screen — the viewDidLoad
        // refresh can run before the extension store's first load completes on a cold relaunch, which
        // left the icon missing for an enabled, un-hidden extension. Idempotent, so no flicker.
        refreshExtensionsToolbarIcon()
    }

    deinit {
        if let chromeLayoutObserver { NotificationCenter.default.removeObserver(chromeLayoutObserver) }
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        if let openURLObserver { NotificationCenter.default.removeObserver(openURLObserver) }
        if let extensionsChangeObserver { NotificationCenter.default.removeObserver(extensionsChangeObserver) }
        if let extensionsToolbarPrefObserver { NotificationCenter.default.removeObserver(extensionsToolbarPrefObserver) }
        if let extensionsToolbarActiveObserver { NotificationCenter.default.removeObserver(extensionsToolbarActiveObserver) }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    /// Keep the omnibox's offset inside the top chrome tracking the status-bar safe-area inset (so the
    /// bar sits just below the status bar, and the scroll-hide distance stays correct after rotation).
    /// Must live in the main class body — Swift forbids overriding inherited methods from an extension.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // In top mode the omnibox sits below the status bar (offset tracks the inset); in bottom mode it
        // sits at a fixed 8pt above the toolbar. Re-applying the position keeps both the offset and the
        // bar height correct across rotation / Dynamic-Island changes, then restore the shown/hidden state.
        guard omniboxTopConstraint != nil else { return }
        let wasHidden = chromeHidden
        applyAddressBarPosition(AppSettings.addressBarPosition, animated: false)
        if wasHidden { chromeHidden = true; applyChromeHidden(true, animated: false) }
    }

    // MARK: - Public entry points (called by SceneDelegate)

    /// Open the first tab on the branded New Tab page if no tabs exist yet — restoring the user's last
    /// session (the tabs they had open when they closed the app) when there is one.
    func openInitialTabIfNeeded() {
        guard tabManager.isEmpty else { return }
        if restoreSavedSession() { return }
        let tab = tabManager.createTab()
        loadNewTabPage(in: tab)
        refreshChrome()
    }

    /// Recreate the tabs persisted at the last app background. Only the ACTIVE tab loads now; the rest keep
    /// a pending URL and load lazily when first selected — so restoring many tabs doesn't stall launch.
    /// Returns false (→ fall back to a fresh New Tab) when there's nothing worth restoring.
    @discardableResult
    private func restoreSavedSession() -> Bool {
        let session = TabSessionStore.load()
        let records = session.records
        guard !records.isEmpty else { return false }
        // A lone blank New Tab is identical to the default fresh start — don't bother "restoring" it.
        if records.count == 1, records[0].url == nil { return false }

        var restored: [Tab] = []
        // Persisted chrome-extension:// / moz-extension:// tabs (an extension's options page, or any
        // extension page it opened in a tab) can't be created as normal tabs — that scheme needs the
        // per-extension scheme handler + page bridge, built asynchronously. We stand up an ordered
        // placeholder for each now (so order, count, and the active index are correct immediately) and
        // upgrade them in place once the loop has run. Pairs the placeholder with its persisted URL.
        var extensionUpgrades: [(placeholder: Tab, url: URL)] = []
        for record in records {
            // The saved title + thumbnail, seeded so the tab grid shows the real title and a preview for a
            // restored tab BEFORE it's activated and actually loads (otherwise every tab read "New Tab").
            let snapshot = record.id.flatMap { TabSnapshotStore.load(id: $0) }
            let url = record.url.flatMap(URL.init(string:))
            let scheme = url?.scheme?.lowercased() ?? ""
            if let url, ["http", "https"].contains(scheme) {
                let tab = tabManager.createTab(loading: url, activate: false)   // pending; loads on activate
                tab.delegate = self
                tab.restoreForDisplay(url: url, title: record.title, snapshot: snapshot)
                restored.append(tab)
            } else if let url, ["chrome-extension", "moz-extension"].contains(scheme) {
                // Placeholder shows the plain New Tab page (no override swap — that would close it and break
                // the in-place upgrade) until upgradeExtensionPlaceholder rebuilds the real extension tab.
                let tab = tabManager.createTab(activate: false)
                tab.delegate = self
                loadNewTabPage(in: tab, allowExtensionOverride: false)
                tab.restoreForDisplay(url: nil, title: record.title, snapshot: snapshot)
                // Persistence-only: if the app backgrounds during the async upgrade window below, persistSession
                // re-emits this extension URL instead of saving the placeholder's nil state.url (which would
                // drop the tab to a blank New Tab next launch). Never auto-loaded — the upgrade does the load.
                tab.restoreURL = url
                restored.append(tab)
                extensionUpgrades.append((tab, url))
            } else {
                let tab = tabManager.createTab(activate: false)
                tab.delegate = self
                loadNewTabPage(in: tab)
                tab.restoreForDisplay(url: nil, title: record.title, snapshot: snapshot)
                restored.append(tab)
            }
            restored.last?.isPinned = record.isPinned ?? false   // restore the pinned state
            if let tab = restored.last {
                // Restore the tab's group membership (the group definitions were loaded by TabManager).
                tabManager.restoreGroupMembership(record.groupID.flatMap(UUID.init), forTab: tab)
            }
        }
        // Activate the saved active tab (installs + loads only it); fall back to the first.
        let index = session.activeIndex.flatMap { restored.indices.contains($0) ? $0 : nil } ?? 0
        if restored.indices.contains(index) {
            tabManager.setActiveTab(restored[index])
        }
        refreshChrome()
        // Now rebuild any extension placeholders in place (extension lookup + page-session config are async).
        if !extensionUpgrades.isEmpty {
            Task { @MainActor in
                for upgrade in extensionUpgrades {
                    await upgradeExtensionPlaceholder(upgrade.placeholder, to: upgrade.url)
                }
            }
        }
        return true
    }

    /// Observe app backgrounding so the open tabs are persisted before the app can be terminated. Called
    /// once during setup. Selector-based (not a closure) so the callback runs synchronously on the main
    /// thread — the persist must complete before the app is suspended — without iOS-17-only isolation APIs.
    func startTabSessionPersistence() {
        NotificationCenter.default.addObserver(self, selector: #selector(persistTabSession),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(persistTabSession),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func persistTabSession() {
        tabManager.persistSession()
    }

    /// Open a URL handed to us by the system (deep link / "open in").
    func handleExternalURL(_ url: URL) {
        let tab = tabManager.createTab(loading: url)
        tab.delegate = self
        tab.loadPendingURLIfNeeded()
        refreshChrome()
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
        // Observe this tab's scroll so the chrome can slide away on scroll-down (+ScrollChrome). Setting
        // the scrollView's delegate is supported and doesn't disturb WKWebView's own scrolling.
        webView.scrollView.delegate = self
        showChrome(animated: false)   // a freshly shown tab always starts with the bar visible
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
        // Start any deferred load; or, if this tab's renderer was reclaimed while it was off-screen,
        // reload its last URL so a re-shown tab renders its page instead of a blank web view.
        tab.loadPendingOrRecover()
    }

    // MARK: - Chrome sync

    /// Push the active tab's state to every chrome surface. Internal so the +Navigation companion file
    /// (the WKNavigationDelegate lifecycle) can refresh chrome on commit/finish/fail.
    func refreshChrome() {
        let state = tabManager.activeTab?.state ?? NavigationState()
        omnibox.update(with: state)
        // Bottom-mode collapsed strip: the domain + its SSL lock (same secure/insecure cue as the omnibox).
        collapsedHostLabel.text = state.displayHost
        let secure = state.hasOnlySecureContent
        collapsedLockGlyph.image = UIImage(systemName: secure ? "lock.fill" : "exclamationmark.triangle.fill")
        collapsedLockGlyph.tintColor = secure ? BrownBearTheme.Palette.secure : BrownBearTheme.Palette.insecure
        collapsedLockGlyph.isHidden = (state.url == nil)   // no lock on the New Tab page (no URL)
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
    /// Reloading the New Tab page must regenerate it (it's an about:blank data document) rather than
    /// reload an empty document. Covers the reload button and pull-to-refresh, which both call tab.reload().
    func tabNeedsNewTabPage(_ tab: Tab) {
        loadNewTabPage(in: tab)
    }

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
        // Refresh the active tab's snapshot in the background so its grid card is fresh by the time the
        // grid presents, and start the hero shrink immediately so the tap feels instant (+TabSwipe).
        tabManager.activeTab?.refreshSnapshot()
        switch AppSettings.tabSwitcherStyle {
        case .grid:
            animateTabGridShrink()
        case .vertical:
            presentVerticalTabs()
        }
    }

    /// The Orion/Kagi-style alternative to the grid: a side panel that slides in over the page from the
    /// user's chosen edge. Presented `.overFullScreen` so the page stays visible behind the scrim.
    func presentVerticalTabs() {
        guard presentedViewController == nil else { return }
        let panel = VerticalTabsPanelViewController(tabManager: tabManager,
                                                    showingPrivate: tabManager.activeTab?.isPrivate ?? false,
                                                    side: AppSettings.verticalTabsSide)
        panel.panelDelegate = self
        present(panel, animated: false)
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

    /// The plain animated present (fallback when a hero snapshot can't be taken).
    func presentTabGrid() {
        let grid = BrownBearTabGridController(tabManager: tabManager,
                                             showingPrivate: tabManager.activeTab?.isPrivate ?? false)
        grid.gridDelegate = self
        grid.modalPresentationStyle = .fullScreen
        grid.transitioningDelegate = tabGridTransition   // spring zoom open/close
        present(grid, animated: true)
    }

    /// Present the tab grid with NO built-in animation — the interactive swipe-up / tab-button shrink
    /// (+TabSwipe) is the transition: `configure` hands the grid the page snapshot + its release frame so the
    /// grid flies it into the active card itself. The transitioning delegate is still set so tapping a card
    /// later dismisses with the zoom-expand.
    func presentTabGridWithoutAnimation(configure: ((BrownBearTabGridController) -> Void)? = nil,
                                        completion: (() -> Void)? = nil) {
        let grid = BrownBearTabGridController(tabManager: tabManager,
                                              showingPrivate: tabManager.activeTab?.isPrivate ?? false)
        grid.gridDelegate = self
        grid.modalPresentationStyle = .fullScreen
        grid.transitioningDelegate = tabGridTransition
        configure?(grid)
        present(grid, animated: false, completion: completion)
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
                actionState.registerManifestAction(extensionID: ext.id, action: action,
                                                   fallbackIcons: ext.manifest?.icons ?? [:])
                let resolved = actionState.resolved(extensionID: ext.id, tabId: actionTabId)
                guard resolved.enabled else { continue }
                extensionActions.append(MenuExtensionAction(
                    extensionID: ext.id,
                    title: Self.webExtMenuActionTitle(resolved.title, ext: ext),
                    badgeText: resolved.badgeText,
                    badgeColor: Self.actionBadgeColor(actionState.badgeColorBytes(extensionID: ext.id, tabId: actionTabId)),
                    badgeTextColor: Self.actionBadgeColor(actionState.badgeTextColorBytes(extensionID: ext.id, tabId: actionTabId)),
                    iconPath: resolved.iconPath,
                    fallbackIconPath: WebExtensionIconResolver.bestIconPath(ext.manifest),
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
                scriptCommands: scriptCommands,
                proxySupported: ProxyManager.isSupported,
                proxyEnabled: ProxyManager.shared.enabled,
                proxyHasActive: ProxyManager.shared.active != nil,
                proxyName: ProxyManager.shared.active?.displayName)
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
        webView.customUserAgent = tab.prefersDesktop ? Self.desktopSafariUserAgent : Self.mobileSafariUserAgent
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

    // Not `private`: the extensions toolbar button's long-press "Manage" opens this (+ExtensionsToolbar).
    func presentDashboard(initialTab: BrownBearDashboardView.DashboardTab = .scripts) {
        present(BrownBearDashboardView.makeHostingController(initialTab: initialTab), animated: true)
    }

    /// Open the proxy config directly (the ••• menu "Proxy" row) in its own sheet, so it's a 2-tap door
    /// from the browser instead of menu → Settings → scroll → Proxy.
    private func presentProxy() {
        present(ProxyView.makeHostingController(), animated: true)
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

    private func presentReadingList() {
        present(ReadingListView.makeHostingController(onOpen: { [weak self] url in
            self?.openBookmark(url)
        }), animated: true)
    }

    /// Save the active tab's page to the reading list, with a brief confirmation toast.
    private func addActiveTabToReadingList() {
        guard let tab = tabManager.activeTab, let url = tab.state.url else { return }
        let title = tab.state.displayTitle
        Task { await BrownBearServices.shared.readingListStore.add(title: title, url: url) }
        presentReadingListToast()
    }

    // Not `private`: the omnibox "see all" suggestions footer (in +Omnibox.swift) opens History too.
    func presentHistory() {
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
        // Activate first so the page is installed behind the grid, then hand the tapped card to the
        // transition so the dismiss expands that card into the now-live page (Safari/Arc morph).
        tabManager.setActiveTab(tab)
        tabGridTransition.selectedCardImage = controller.selectedCardImage
        tabGridTransition.selectedCardFrame = controller.selectedCardFrame
        // The card snapshot is a render of the web view's content area; grow it to that area so it lands 1:1
        // on the live page instead of over-zoomed (no zoom-out "snap" on dissolve). Convert to our OWN view,
        // NOT `to: nil` (window): under the full-screen tab-grid modal UIKit detaches this view from the
        // window, so a window conversion returns .zero — which made the hero fall back to the FULL screen
        // (~13% over-sized, landing too tall/high). Our view fills the screen at the origin, so its coords
        // equal the window's and the transition container's.
        tabGridTransition.selectedContentFrame = contentContainer.convert(contentContainer.bounds, to: view)
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

// MARK: - VerticalTabsPanelDelegate (Orion/Kagi side panel)

extension BrownBearBrowserViewController: VerticalTabsPanelDelegate {
    func verticalTabsPanel(_ panel: VerticalTabsPanelViewController, didSelect tab: Tab) {
        // Activate first so the page is live behind the panel, then slide the panel away to reveal it.
        tabManager.setActiveTab(tab)
        panel.dismissPanel { [weak self] in self?.refreshChrome() }
    }

    func verticalTabsPanel(_ panel: VerticalTabsPanelViewController, didRequestNewTabPrivate isPrivate: Bool) {
        let tab = tabManager.createTab(isPrivate: isPrivate)
        loadNewTabPage(in: tab)
        panel.dismissPanel { [weak self] in
            self?.refreshChrome()
            self?.omnibox.beginEditing()
        }
    }

    func verticalTabsPanelDidRequestDismiss(_ panel: VerticalTabsPanelViewController) {
        panel.dismissPanel(completion: nil)
    }
}

// MARK: - WKUIDelegate (target="_blank" → new tab)

extension BrownBearBrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A target="_blank" link to a *.user.js (common on Greasy Fork / GitHub raw) must NOT spawn a
        // blank tab that then dumps raw JS — hand it to an installed userscript manager that claims it,
        // or show BrownBear's native install card, and open no window.
        if let url = navigationAction.request.url,
           ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
           UserScriptInstaller.isUserScriptURL(url) {
            handleUserScriptInstall(for: url)
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
    func bridgeOpenInTab(url: URL, active: Bool, onClose: @escaping () -> Void) -> (() -> Void)? {
        let tab = tabManager.createTab(loading: url, activate: active)
        tab.delegate = self
        // A GM_openInTab tab is a plain browsing tab (onClose is otherwise only used for NTP/extension
        // session teardown), so it's free to back the script's handle.onclose.
        tab.onClose = onClose
        tab.loadPendingURLIfNeeded()
        if active { refreshChrome() }
        return { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.tabManager.closeTab(id: tab.id)
        }
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
        case .fullPageScreenshot:
            captureFullPageScreenshot()
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
        case .addToReadingList:
            addActiveTabToReadingList()
        case .readingList:
            presentReadingList()
        case .history:
            presentHistory()
        case .downloads:
            presentDownloads()
        case .settings:
            presentDashboard(initialTab: .settings)
        case .proxy:
            presentProxy()
        case .reader:
            presentReader()
        case .translatePage:
            presentTranslatePage()
        case .zoom:
            presentZoomHUD()
        }
    }

    func browserMenu(_ menu: BrowserMenuViewController, didToggleScript id: UUID, enabled: Bool) {
        // Persist the toggle; re-injection happens on the next navigation (no hot re-inject), which
        // matches the engine's existing behavior.
        Task { await BrownBearServices.shared.scriptStore.setEnabled(id: id, enabled) }
    }

    func browserMenu(_ menu: BrowserMenuViewController, didToggleProxy enabled: Bool) {
        // The inline switch flips the active proxy on/off without closing the menu; ProxyManager re-applies
        // it to the live data stores. Reload the active tab so the current page picks up the change.
        ProxyManager.shared.setEnabled(enabled)
        tabManager.activeTab?.reload()
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
