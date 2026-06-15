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

    /// The non-persistent store shared by the CURRENT batch of private tabs (they share a cookie jar so
    /// a login flow spanning a popup works, fully isolated from normal browsing). Made disposable rather
    /// than wiped-in-place: closing the last private tab detaches this reference and wipes the detached
    /// object, so a brand-new private session always gets a FRESH store and can never share one with a
    /// pending wipe. nil until the first private tab is created.
    private var privateDataStore: WKWebsiteDataStore?

    /// Observer that re-applies the proxy to live stores whenever the user changes it in Settings.
    private var proxyObserver: NSObjectProtocol?

    /// Serves extensions' web_accessible_resources to normal pages (a content script's getURL() loaded by
    /// the page). One instance, reused across tabs/schemes — it's stateless except per-task lifecycle.
    private let warSchemeHandler = WebExtensionWARSchemeHandler()

    init(injection: InjectionOrchestrator) {
        self.injection = injection
        // Route browsing through the user's proxy (iOS 17+), and re-apply whenever it changes so toggling
        // it on/off in Settings takes effect on the next request without recreating the data store.
        ProxyManager.shared.apply(to: websiteDataStore)
        proxyObserver = NotificationCenter.default.addObserver(
            forName: .brownBearProxyDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyProxyToLiveStores() }
        }
    }

    deinit {
        if let proxyObserver { NotificationCenter.default.removeObserver(proxyObserver) }
    }

    /// Re-apply the current proxy to every live data store (the persistent one and the current private one).
    private func applyProxyToLiveStores() {
        ProxyManager.shared.apply(to: websiteDataStore)
        if let privateDataStore { ProxyManager.shared.apply(to: privateDataStore) }
    }

    /// Produce a fresh configuration for a new web view, wired into the shared content controller and
    /// process pool. Private tabs get the non-persistent data store; normal tabs the default store.
    func makeConfiguration(isPrivate: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.userContentController = injection.userContentController
        if isPrivate {
            let store = privateDataStore ?? WKWebsiteDataStore.nonPersistent()
            privateDataStore = store
            ProxyManager.shared.apply(to: store)   // a fresh private store needs the active proxy too
            config.websiteDataStore = store
        } else {
            config.websiteDataStore = websiteDataStore
        }
        // Let a page load an extension's web_accessible_resources (a content script's getURL() referenced in
        // the DOM). Fail-closed inside the handler — only declared WAR resources to matching origins; the
        // scheme is otherwise unhandled here and the load just fails (no regression).
        config.setURLSchemeHandler(warSchemeHandler, forURLScheme: WebExtensionSchemeHandler.scheme)
        config.setURLSchemeHandler(warSchemeHandler, forURLScheme: WebExtensionSchemeHandler.firefoxScheme)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true   // floating-window video (paired with the
        // `audio` background mode + the .playback audio session set in AppDelegate)
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

    /// The WKHTTPCookieStore for a chrome.cookies store id. iOS exposes a single store ("0"), backed by
    /// the persistent default jar normal tabs share; a nil id resolves it, any other id yields nil
    /// (chrome rejects an unknown storeId). Private tabs' non-persistent jar is intentionally NOT
    /// exposed to extensions — it has no chrome store id and is wiped on last-private-tab close.
    func httpCookieStore(forStoreId id: String?) -> WKHTTPCookieStore? {
        switch id {
        case nil, WebExtensionCookieMapper.storeId: return websiteDataStore.httpCookieStore
        default: return nil
        }
    }

    /// Synchronously detach the current private store (so any NEW private tab gets a fresh one) and
    /// return it for wiping. Called at last-private-tab close BEFORE the async wipe, so a private tab
    /// opened in the same run loop can never end up sharing a store that's about to be erased. Returns
    /// nil if no private store was ever created.
    func detachPrivateDataStoreForWipe() -> WKWebsiteDataStore? {
        let old = privateDataStore
        privateDataStore = nil
        return old
    }

    /// Erase all data (cookies, cache, local storage) from a detached private store so a private
    /// session leaves nothing behind. Pass the object returned by detachPrivateDataStoreForWipe().
    func wipePrivateData(_ store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
