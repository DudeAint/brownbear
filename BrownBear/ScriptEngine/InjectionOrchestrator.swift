//
//  InjectionOrchestrator.swift
//  BrownBear
//
//  Wires the userscript runtime into WebKit. It owns the shared WKUserContentController used by
//  every tab and configures three things, once:
//    1. An isolated WKContentWorld ("BrownBear") so injected code and the GM bridge are
//       invisible to (and untamperable by) the page — the sandbox boundary.
//    2. The `brownbear` reply message handler (ScriptMessageRouter) in that world.
//    3. A single bootstrap WKUserScript at atDocumentStart that loads the matching scripts and
//       gates them by @run-at. The bootstrap is constant; matching happens live via getScripts,
//       so installing/editing/toggling scripts takes effect on the next navigation with no
//       re-injection.
//

import WebKit

@MainActor
final class InjectionOrchestrator {

    /// The content controller every tab's configuration shares.
    let userContentController = WKUserContentController()

    /// Isolated world for all BrownBear injection. Page scripts cannot reach into it.
    let contentWorld = WKContentWorld.world(name: "BrownBear")

    private let router: ScriptMessageRouter
    private let webExtensionRouter: WebExtensionMessageRouter
    /// Captures the page's own console.* output (PAGE world) for the Logs "Page" filter.
    private let pageConsoleHandler: PageConsoleHandler
    /// Captures same-document history changes (pushState/replaceState/popstate, PAGE world) so
    /// chrome.webNavigation.onHistoryStateUpdated can fire — WKWebView's nav delegate never reports them.
    let historyStateHandler = WebExtHistoryStateHandler()
    /// Backs the in-page "Add to BrownBear" / "Remove from BrownBear" button on Chrome Web Store pages.
    private let webStoreInstallHandler = WebStoreInstallHandler()
    /// Compiles each extension's declarativeNetRequest rulesets into WKContentRuleLists (Module 6 P2).
    let contentBlocker: WebExtensionContentBlocker
    let scriptStore: ScriptStore
    let valueStore: GMValueStore
    private let network = GMNetworkService()
    private var extensionsObserver: NSObjectProtocol?
    private var blocklistObserver: NSObjectProtocol?

    /// Forwarded to the router so GM_openInTab can reach the browser.
    weak var bridgeHost: ScriptBridgeHost? {
        didSet { router.host = bridgeHost }
    }

    /// Forwarded to the extension content/popup router AND the background runtime so chrome.tabs (and
    /// the rest of the tab surface) can reach TabManager from every surface.
    weak var webExtensionBridgeHost: WebExtensionBridgeHost? {
        didSet {
            webExtensionRouter.host = webExtensionBridgeHost
            BrownBearServices.shared.webExtensionRuntime.host = webExtensionBridgeHost
        }
    }

    /// Forwarded to the content/popup router AND the background runtime so chrome.cookies can reach the
    /// browser's WKHTTPCookieStore from every surface (the browser VC implements this).
    weak var webExtensionCookieHost: WebExtensionCookieBridgeHost? {
        didSet {
            webExtensionRouter.cookieHost = webExtensionCookieHost
            BrownBearServices.shared.webExtensionRuntime.cookieHost = webExtensionCookieHost
        }
    }

    /// Watches the default cookie jar and fans chrome.cookies.onChanged out to workers/pages. Owned
    /// here (app-lifetime) and started in configure(), alongside the background runtime.
    private let cookieObserver = WebExtensionCookieObserver(store: WKWebsiteDataStore.default().httpCookieStore)

    init(scriptStore: ScriptStore = BrownBearServices.shared.scriptStore,
         valueStore: GMValueStore = BrownBearServices.shared.valueStore,
         logStore: LogStore = BrownBearServices.shared.logStore,
         webExtensionStore: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         webExtensionStorage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage) {
        self.scriptStore = scriptStore
        self.valueStore = valueStore
        self.router = ScriptMessageRouter(scriptStore: scriptStore,
                                          valueStore: valueStore,
                                          network: network,
                                          logStore: logStore,
                                          contentWorld: contentWorld)
        self.webExtensionRouter = WebExtensionMessageRouter(store: webExtensionStore,
                                                            storage: webExtensionStorage,
                                                            runtime: BrownBearServices.shared.webExtensionRuntime,
                                                            contentWorld: contentWorld)
        self.contentBlocker = WebExtensionContentBlocker(store: webExtensionStore)
        self.pageConsoleHandler = PageConsoleHandler(logStore: logStore)
        configure()
    }

    deinit {
        if let extensionsObserver { NotificationCenter.default.removeObserver(extensionsObserver) }
        if let blocklistObserver { NotificationCenter.default.removeObserver(blocklistObserver) }
    }

    // MARK: - Setup

    private func configure() {
        // requestIdleCallback / cancelIdleCallback polyfill — FIRST, so it precedes every other script in
        // both worlds. WebKit ships neither in any JS world (Safari has never implemented them); Chrome has
        // both in every window context, so an extension content script or userscript that calls
        // requestIdleCallback (ScriptCat's content runtime does) otherwise throws a bare ReferenceError and
        // dies. Page world (page scripts + MAIN-world userscripts) AND our isolated content world (content
        // scripts + isolated userscripts); NOT the background JSContext — service workers lack rIC in Chrome.
        for world in [WKContentWorld.page, contentWorld] {
            let idlePolyfill = WKUserScript(source: Self.bootstrapSource("brownbear-idle-callback"),
                                            injectionTime: .atDocumentStart,
                                            forMainFrameOnly: false,
                                            in: world)
            userContentController.addUserScript(idlePolyfill)
        }

        // Userscript runtime.
        userContentController.addScriptMessageHandler(router,
                                                      contentWorld: contentWorld,
                                                      name: ScriptMessageRouter.handlerName)
        addBootstrap(resource: "brownbear-runtime")

        // Browser-extension runtime (Module 6).
        userContentController.addScriptMessageHandler(webExtensionRouter,
                                                      contentWorld: contentWorld,
                                                      name: WebExtensionMessageRouter.handlerName)
        addBootstrap(resource: "brownbear-webext-runtime")

        // Resilient event listeners — PAGE world, document-start, BEFORE any page script. Keeps
        // window.addEventListener/removeEventListener working even if the page replaces them with a
        // wrapper that throws (a blocked analytics agent like New Relic poisons the global this way and
        // takes down the page's code AND any MAIN-world userscript). Pure page-side, no handler; a
        // transparent pass-through to the native for the vast majority of pages that never override these.
        let resilientEvents = WKUserScript(source: Self.bootstrapSource("brownbear-resilient-events"),
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false,
                                           in: .page)
        userContentController.addUserScript(resilientEvents)

        // "Keep videos inline" — page-world shim that neutralizes scripted/auto fullscreen so videos stay
        // in the page (the Focus/Player behavior). Opt-in; installed on the shared controller at boot, so
        // toggling it takes effect on the next app launch (documented in Settings).
        if AppSettings.keepVideosInline {
            let inlineVideo = WKUserScript(source: Self.bootstrapSource("brownbear-inline-video"),
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false,
                                           in: .page)
            userContentController.addUserScript(inlineVideo)
        }

        // Page-console capture — registered in the PAGE world (not the isolated bridge world) with
        // its own handler, so the page's console.* can be surfaced in the Logs "Page" filter without
        // ever exposing the privileged BrownBear bridge to page scripts.
        userContentController.add(pageConsoleHandler,
                                  contentWorld: .page,
                                  name: PageConsoleHandler.handlerName)
        let pageConsole = WKUserScript(source: Self.bootstrapSource("brownbear-pageconsole"),
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false,
                                       in: .page)
        userContentController.addUserScript(pageConsole)

        // Chrome Web Store in-page install button — a PAGE-world content script that self-gates to
        // store hosts, makes the store believe it's desktop Chrome, and rewires the install button to
        // BrownBear's installer via the reply handler below. Main frame only (the button is there).
        userContentController.addScriptMessageHandler(webStoreInstallHandler,
                                                      contentWorld: .page,
                                                      name: WebStoreInstallHandler.handlerName)
        let webStore = WKUserScript(source: Self.bootstrapSource("brownbear-webstore"),
                                    injectionTime: .atDocumentStart,
                                    forMainFrameOnly: true,
                                    in: .page)
        userContentController.addUserScript(webStore)

        // Same-document history capture for chrome.webNavigation.onHistoryStateUpdated — a PAGE-world
        // hook (history.pushState lives in page scope) that posts the new URL to native, which emits the
        // webNavigation event. Main frame only. The handler does NO privileged work (untrusted PAGE
        // world); it only forwards a validated http(s) main-frame URL for an event emission.
        userContentController.add(historyStateHandler,
                                  contentWorld: .page,
                                  name: WebExtHistoryStateHandler.handlerName)
        let historyHook = WKUserScript(source: Self.bootstrapSource("brownbear-webext-histstate"),
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true,
                                       in: .page)
        userContentController.addUserScript(historyHook)

        // Boot background service workers + the content↔background message bus (self-observes
        // extension changes thereafter).
        BrownBearServices.shared.webExtensionRuntime.start()

        // Start watching the cookie jar so chrome.cookies.onChanged fires for ordinary browsing and
        // for extension-initiated set/remove.
        cookieObserver.start()

        // Compile declarativeNetRequest rulesets now, and recompile whenever extensions change.
        refreshExtensionContentBlockers()
        extensionsObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshExtensionContentBlockers() }
        }

        // Refresh BrownBear's built-in ad/tracker list from the maintained upstreams (uBlock-style),
        // then recompile so the larger merged list takes effect. Fire-and-forget; offline keeps the
        // bundled starter list. Recompile whenever a newer merged list lands.
        blocklistObserver = NotificationCenter.default.addObserver(
            forName: .brownBearBlocklistDidUpdate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshExtensionContentBlockers() }
        }
        ContentBlocklistUpdater.shared.updateIfStale()
    }

    /// chrome.tabs.sendMessage delivery. Hands off to the shared extension content router, which owns
    /// the per-tab content sessions and pushes the message into the matching content scripts'
    /// runtime.onMessage listeners. Resolves with the first listener's response (or nil). The browser
    /// view controller resolves the target tab → web view before calling this.
    func webExtSendMessageToTab(extensionID: String, webView: WKWebView, message: Any, frameId: Int?) async -> Any? {
        await webExtensionRouter.sendMessageToTab(extensionID: extensionID,
                                                  webView: webView,
                                                  message: message,
                                                  frameId: frameId)
    }

    /// chrome.scripting.executeScript frame targeting — evaluate into the main frame and/or the frames
    /// where this extension's content scripts run (the router owns those sessions). One InjectionResult
    /// per evaluated frame. The browser VC resolves the tab → web view before calling this.
    func webExtEvaluateInContentFrames(extensionID: String, webView: WKWebView, world: WKContentWorld,
                                       code: String, frameIds: [Int]?, allFrames: Bool) async -> [[String: Any]] {
        await webExtensionRouter.evaluateInContentFrames(extensionID: extensionID,
                                                         webView: webView,
                                                         world: world,
                                                         code: code,
                                                         frameIds: frameIds,
                                                         allFrames: allFrames)
    }

    // MARK: - Userscript menu commands & per-tab GM tab objects (GM_registerMenuCommand / GM_getTab)

    /// The active tab's userscript menu commands (registration order) — the browser builds the menu's
    /// "Script commands" section from these. Resolved off the active tab's web view so a command a
    /// script registered in any frame of that tab appears.
    func userScriptMenuCommands(in webView: WKWebView) -> [UserScriptMenuCommand] {
        router.menuCommands(in: webView)
    }

    /// Fire a tapped menu command back into the exact frame/world its script runs in. Returns false if
    /// the command no longer exists (so the browser can drop a stale row silently).
    @discardableResult
    func fireUserScriptMenuCommand(token: String, commandID: String) -> Bool {
        router.fireMenuCommand(token: token, commandID: commandID)
    }

    /// Drop a closed tab's per-tab GM tab objects (GM_getTab/GM_saveTab), so they don't outlive it.
    func forgetUserScriptTabObjects(tabID: Int) {
        router.forgetTabObjects(tabID: tabID)
    }

    /// Recompile and reinstall every enabled extension's content-blocking rules. Fire-and-forget;
    /// the next navigation picks up the new rule lists.
    func refreshExtensionContentBlockers() {
        let controller = userContentController
        Task {
            // Hosts the user pinned Shields-off for (blockContent == false) are excluded from blocking.
            let disabled = await BrownBearServices.shared.siteSettingsStore.allHosts()
                .filter { $0.settings.blockContent == false }
                .map(\.host)
            await contentBlocker.refresh(into: controller, shieldsDisabledHosts: disabled)
        }
    }

    private func addBootstrap(resource: String) {
        let bootstrap = WKUserScript(source: Self.bootstrapSource(resource),
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false,
                                     in: contentWorld)
        userContentController.addUserScript(bootstrap)
    }

    // MARK: - Bootstrap source

    /// Load an injected runtime closure from the app bundle.
    private static func bootstrapSource(_ resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: resource, withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            // If the resource is missing we inject nothing rather than crash; CI's js-runtime job
            // guards the files' presence and syntax.
            return "/* BrownBear runtime resource \(resource) missing */"
        }
        return source
    }
}
