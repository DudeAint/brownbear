//
//  WebViewConfigurationFactory.swift
//  BrownBear
//
//  Produces the WKWebViewConfiguration every tab shares. Centralizing this matters because
//  Modules 2–3 inject userscripts through a single WKUserContentController: every tab must be
//  built from a configuration that wires that controller in consistently. For Module 1 the
//  content controller is empty; the injection pipeline plugs into `userContentController` later.
//

import WebKit

/// Builds and vends the shared web configuration for all tabs.
final class WebViewConfigurationFactory {

    /// One process pool shared across tabs so they can share cookies/session state like a
    /// real multi-tab browser.
    private let processPool = WKProcessPool()

    /// The shared content controller. Module 2's `InjectionOrchestrator` will register its
    /// `WKUserScript`s and `WKScriptMessageHandler`s here.
    let userContentController = WKUserContentController()

    /// A non-persistent option could be added later for a private mode; default is persistent.
    private let websiteDataStore = WKWebsiteDataStore.default()

    /// Produce a fresh configuration for a new web view. The returned object is safe to mutate
    /// per-tab, but it points at the shared process pool and content controller.
    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.userContentController = userContentController
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
