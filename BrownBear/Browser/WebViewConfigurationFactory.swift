//
//  WebViewConfigurationFactory.swift
//  BrownBear
//
//  Produces the WKWebViewConfiguration every tab shares. The content controller comes from the
//  InjectionOrchestrator (Modules 2–3), so every tab is wired into the same userscript runtime:
//  the bootstrap WKUserScript and the `brownbear` message handler in the isolated content world.
//

import WebKit

@MainActor
final class WebViewConfigurationFactory {

    /// One process pool shared across tabs so they can share cookies/session state.
    private let processPool = WKProcessPool()

    /// Owns the shared content controller + the injected userscript runtime.
    let injection: InjectionOrchestrator

    private let websiteDataStore = WKWebsiteDataStore.default()

    init(injection: InjectionOrchestrator) {
        self.injection = injection
    }

    /// Produce a fresh configuration for a new web view, wired into the shared content
    /// controller and process pool.
    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.userContentController = injection.userContentController
        config.websiteDataStore = websiteDataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.applicationNameForUserAgent = "BrownBear"

        let prefs = WKPreferences()
        prefs.isFraudulentWebsiteWarningEnabled = true
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs

        return config
    }
}
