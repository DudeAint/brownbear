//
//  BrownBearBrowserViewController+ExtensionPageTabs.swift
//  BrownBear
//
//  Opens an extension page (its options page, or any chrome-extension:// resource it asks to open in a
//  tab) as a REAL browser tab rather than a modal sheet — the Orion/Gear behaviour the "•••" Options
//  action and chrome.runtime.openOptionsPage should give. A normal tab can't serve chrome-extension://
//  or run the chrome.* page bridge, so we build a bespoke configuration (per-extension scheme handler +
//  brownbear-webext-page.js) via WebExtensionPageSession and adopt it into a new tab. The tab OWNS the
//  bridge session for its lifetime (Tab.onClose retains it) and tears it down on close, so the worker's
//  chrome.runtime.onDisconnect fires promptly; the router holds the web view weakly, so there's no cycle.
//

import UIKit

extension BrownBearBrowserViewController {

    /// Open an extension page in a real browser tab. `path` overrides the manifest's kind-default page
    /// (used when an extension opens an arbitrary `chrome-extension://<id>/<path>` of its own via
    /// chrome.tabs.create). Returns false if the requested page doesn't exist (so callers can surface
    /// chrome.runtime.lastError), true once the tab is on its way.
    @MainActor
    @discardableResult
    func openExtensionPageTab(ext: WebExtension,
                              kind: WebExtensionPageSession.Kind,
                              path: String? = nil,
                              activate: Bool = true) -> Bool {
        let session = WebExtensionPageSession(ext: ext, kind: kind, path: path)
        guard session.pageURL != nil else { return false }
        // Drop any presented popup/sheet/menu so the freshly opened tab is actually visible behind it.
        TopViewControllerPresenter.dismissTopPresented()
        Task { @MainActor in
            guard let url = session.pageURL else { return }
            let configuration = await session.makeConfiguration()
            // Adopt the bespoke configuration (createTab(adopting:) activates it, which installs the web
            // view and refreshes the chrome via the TabManager delegate — no extra refresh needed).
            let tab = tabManager.createTab(adopting: configuration, activate: activate, isPrivate: false)
            tab.delegate = self
            tab.onClose = { session.invalidate() }   // retains the session for the tab's life; tears down on close
            session.bind(to: tab.webView)            // wire ports + live storage/cookie/notification push before load
            tab.load(url)
        }
        return true
    }
}
