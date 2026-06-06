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
    /// Compiles each extension's declarativeNetRequest rulesets into WKContentRuleLists (Module 6 P2).
    let contentBlocker: WebExtensionContentBlocker
    let scriptStore: ScriptStore
    let valueStore: GMValueStore
    private let network = GMNetworkService()
    private var extensionsObserver: NSObjectProtocol?

    /// Forwarded to the router so GM_openInTab can reach the browser.
    weak var bridgeHost: ScriptBridgeHost? {
        didSet { router.host = bridgeHost }
    }

    init(scriptStore: ScriptStore = BrownBearServices.shared.scriptStore,
         valueStore: GMValueStore = BrownBearServices.shared.valueStore,
         webExtensionStore: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         webExtensionStorage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage) {
        self.scriptStore = scriptStore
        self.valueStore = valueStore
        self.router = ScriptMessageRouter(scriptStore: scriptStore,
                                          valueStore: valueStore,
                                          network: network,
                                          contentWorld: contentWorld)
        self.webExtensionRouter = WebExtensionMessageRouter(store: webExtensionStore,
                                                            storage: webExtensionStorage,
                                                            runtime: BrownBearServices.shared.webExtensionRuntime)
        self.contentBlocker = WebExtensionContentBlocker(store: webExtensionStore)
        configure()
    }

    deinit {
        if let extensionsObserver { NotificationCenter.default.removeObserver(extensionsObserver) }
    }

    // MARK: - Setup

    private func configure() {
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

        // Boot background service workers + the content↔background message bus (self-observes
        // extension changes thereafter).
        BrownBearServices.shared.webExtensionRuntime.start()

        // Compile declarativeNetRequest rulesets now, and recompile whenever extensions change.
        refreshExtensionContentBlockers()
        extensionsObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshExtensionContentBlockers() }
        }
    }

    /// Recompile and reinstall every enabled extension's content-blocking rules. Fire-and-forget;
    /// the next navigation picks up the new rule lists.
    func refreshExtensionContentBlockers() {
        let controller = userContentController
        Task { await contentBlocker.refresh(into: controller) }
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
