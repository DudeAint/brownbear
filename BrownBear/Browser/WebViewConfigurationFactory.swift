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

    /// The persistent store every normal tab shares (cookies/cache survive launches).
    private let websiteDataStore = WKWebsiteDataStore.default()

    /// One non-persistent store shared by all private tabs: they share a cookie jar with each other
    /// (so a login flow that spans a popup works) but are fully isolated from normal browsing, and
    /// everything is discarded when the store is released or explicitly wiped on closing the last
    /// private tab. Created lazily so apps that never use private mode pay nothing.
    private lazy var privateDataStore = WKWebsiteDataStore.nonPersistent()

    init(injection: InjectionOrchestrator) {
        self.injection = injection
    }

    /// Produce a fresh configuration for a new web view, wired into the shared content controller and
    /// process pool. Private tabs get the non-persistent data store; normal tabs the default store.
    func makeConfiguration(isPrivate: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.userContentController = injection.userContentController
        config.websiteDataStore = isPrivate ? privateDataStore : websiteDataStore
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

    /// Erase all data (cookies, cache, local storage) from the private store. Called when the last
    /// private tab closes so a private session leaves nothing behind, even though the store object
    /// itself is reused for the app's lifetime.
    func wipePrivateData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await privateDataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
