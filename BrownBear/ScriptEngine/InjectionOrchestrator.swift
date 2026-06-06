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
    let scriptStore: ScriptStore
    let valueStore: GMValueStore
    private let network = GMNetworkService()

    /// Forwarded to the router so GM_openInTab can reach the browser.
    weak var bridgeHost: ScriptBridgeHost? {
        didSet { router.host = bridgeHost }
    }

    init(scriptStore: ScriptStore = ScriptStore(),
         valueStore: GMValueStore = GMValueStore()) {
        self.scriptStore = scriptStore
        self.valueStore = valueStore
        self.router = ScriptMessageRouter(scriptStore: scriptStore,
                                          valueStore: valueStore,
                                          network: network,
                                          contentWorld: contentWorld)
        configure()
    }

    // MARK: - Setup

    private func configure() {
        userContentController.addScriptMessageHandler(router,
                                                      contentWorld: contentWorld,
                                                      name: ScriptMessageRouter.handlerName)

        let bootstrap = WKUserScript(source: Self.bootstrapSource(),
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false,
                                     in: contentWorld)
        userContentController.addUserScript(bootstrap)
    }

    // MARK: - Bootstrap source

    /// The injected runtime (brownbear-runtime.js): one closure containing the private bridge,
    /// the GM surface, and the loader. Loaded from the app bundle.
    private static func bootstrapSource() -> String {
        guard let url = Bundle.main.url(forResource: "brownbear-runtime", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-runtime", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            // If the resource is missing we inject nothing rather than crash; CI's js-runtime job
            // guards the file's presence and syntax.
            return "/* BrownBear runtime resource missing */"
        }
        return source
    }
}
