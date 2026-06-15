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

    /// Rebuild a persisted extension page (`chrome-extension://` / `moz-extension://`) into a real tab,
    /// swapping it in place of the New-Tab placeholder session restore stood up for it. A normal tab can't
    /// host that scheme, so — exactly as `openExtensionPageTab` does for a fresh open — we build a bespoke
    /// per-extension page session and adopt its configuration. The tab OWNS the session for its lifetime
    /// (`onClose` tears it down). No-ops (leaving the placeholder as a New Tab) when the extension was
    /// uninstalled or disabled since the session was saved, or the resource no longer exists.
    @MainActor
    func upgradeExtensionPlaceholder(_ placeholder: Tab, to url: URL) async {
        guard let host = url.host, !host.isEmpty,
              let ext = await BrownBearServices.shared.webExtensionStore.ext(for: host), ext.enabled else {
            // The extension was uninstalled/disabled since the session was saved — stop trying to restore it.
            // Clearing restoreURL makes the next persist save url=nil so it's a clean New Tab next launch,
            // rather than perpetually re-restoring a New Tab still wearing the gone extension's title/thumbnail.
            placeholder.restoreURL = nil
            return
        }
        // The packaged resource + whether this restores as a newtab-override page (a Momentum/Tabliss
        // override may branch on __bbExtPage.kind === "newtab"); any other page restores as an options tab.
        let plan = Self.extensionRestorePlan(url: url, newTabOverride: ext.manifest?.newTabOverride)
        let kind: WebExtensionPageSession.Kind = plan.isNewTabOverride ? .newtab : .options
        let session = WebExtensionPageSession(ext: ext, kind: kind,
                                              path: plan.resource.isEmpty ? nil : plan.resource)
        guard session.pageURL != nil else { placeholder.restoreURL = nil; return }
        let configuration = await session.makeConfiguration()
        guard let pageURL = session.pageURL,
              let realTab = tabManager.replaceTab(placeholder, adopting: configuration) else { return }
        realTab.delegate = self
        // Persistence-only fallback for the real tab's pre-commit window: until WebKit commits the
        // chrome-extension navigation, realTab.state.url is nil, so a background in that gap would otherwise
        // persist url=nil. Cleared implicitly once the page commits (persist prefers state.url/lastCommittedURL).
        realTab.restoreURL = pageURL
        realTab.onClose = { session.invalidate() }   // retain the session for the tab's life; tears down on close
        session.bind(to: realTab.webView)            // wire ports + live storage/cookie/notification push before load
        realTab.load(pageURL)
    }

    /// The restore plan for a persisted extension page URL: the packaged `resource` — everything after
    /// `scheme://host/`, i.e. path + any query/fragment, so the page lands on the exact resource it was on
    /// — and `isNewTabOverride`, true iff its path equals the extension's `chrome_url_overrides.newtab`
    /// path (so it restores as a newtab page rather than an options-style page). Pure (no extension lookup,
    /// no web view) so the prefix-strip and newtab detection are unit-testable apart from the async build.
    nonisolated static func extensionRestorePlan(url: URL, newTabOverride: String?)
        -> (resource: String, isNewTabOverride: Bool) {
        let prefix = "\(url.scheme ?? "")://\(url.host ?? "")/"
        let resource = url.absoluteString.hasPrefix(prefix)
            ? String(url.absoluteString.dropFirst(prefix.count)) : ""
        let onlyPath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let override = newTabOverride.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let isNewTabOverride = (override != nil && !onlyPath.isEmpty && override == onlyPath)
        return (resource, isNewTabOverride)
    }
}
