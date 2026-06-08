//
//  BrownBearBrowserViewController+Navigation.swift
//  BrownBear
//
//  The WKNavigationDelegate lifecycle (didStartProvisionalNavigation -> didCommit -> didFinish, plus
//  decidePolicyFor / failures / downloads), split out of the main controller to keep it under the
//  SwiftLint file-length limit. This is the PUSH side of chrome.tabs.* / chrome.webNavigation.* events
//  and the userscript-install interception. The controller members it touches (installedWebView,
//  viewSourceAllowOnce, refreshChrome, pendingNavTargets, progressBar, webExtEvents, ...) are internal
//  for exactly this cross-file split.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.show()
        progressBar.setProgress(0.05, animated: false)
        // Reveal the chrome for a new page load — you should never land on a page with the bar hidden.
        if webView == installedWebView { showChrome(animated: true) }
        // Consume the captured navigation target (cleared once used); fall back to webView.url only if
        // none was captured (e.g. a navigation that didn't pass through decidePolicyFor).
        let captured = pendingNavTargets.removeValue(forKey: ObjectIdentifier(webView))
        if let id = extTabId(for: webView) {
            webExtEvents.webNavBeforeNavigate(
                extTabId: id, url: Self.beforeNavigateURL(captured: captured, fallback: webView.url?.absoluteString))
        }
    }

    /// onBeforeNavigate's URL: the navigation TARGET captured at policy time, else the web view's
    /// current URL, else "". Pulled out so the capture-vs-fallback choice is unit-testable.
    static func beforeNavigateURL(captured: String?, fallback: String?) -> String {
        captured ?? fallback ?? ""
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The page's main document has started rendering — refresh the security indicator.
        if webView == installedWebView { refreshChrome() }
        applyStoredZoom(for: webView)
        if let id = extTabId(for: webView) {
            webExtEvents.webNavCommitted(extTabId: id, url: webView.url?.absoluteString ?? "")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressBar.complete()
        if webView == installedWebView { refreshChrome() }
        recordHistory(for: webView)
        // WKWebView gives no separate DOMContentLoaded; fire both at didFinish (DOMContentLoaded first),
        // which is the common shim behavior — documented in docs/WEB_EXTENSIONS.md.
        if let id = extTabId(for: webView) {
            let url = webView.url?.absoluteString ?? ""
            webExtEvents.webNavDOMContentLoaded(extTabId: id, url: url)
            webExtEvents.webNavCompleted(extTabId: id, url: url)
        }
    }

    /// The chrome tab id for the tab backing `webView`, or nil if none (for webNavigation events).
    func extTabId(for webView: WKWebView) -> Int? {
        tabManager.tabs.first { $0.webView === webView }.map { webExtTabRegistry.id(for: $0.id) }
    }

    /// Record a finished main-frame navigation in browsing history. Only real web pages are kept —
    /// about:blank (the New Tab page), data:, and file: URLs are skipped, as are app schemes (which
    /// never reach didFinish here). Private tabs are never recorded.
    private func recordHistory(for webView: WKWebView) {
        // Skip private tabs — an incognito session must leave no history trace.
        if let tab = tabManager.tabs.first(where: { $0.webView === webView }), tab.isPrivate { return }
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let title = webView.title
        Task { await BrownBearServices.shared.historyStore.record(url: url, title: title) }
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.complete()
        if let id = extTabId(for: webView) {
            webExtEvents.webNavErrorOccurred(extTabId: id, url: webView.url?.absoluteString ?? "",
                                             error: (error as NSError).localizedDescription)
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.complete()
        // Ignore user-initiated cancellations (e.g. tapping a new link mid-load).
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        if let id = extTabId(for: webView) {
            webExtEvents.webNavErrorOccurred(extTabId: id, url: webView.url?.absoluteString ?? "",
                                             error: nsError.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // Apply the tab's desktop/mobile choice to every navigation. preferredContentMode is the
        // reliable lever (a desktop UA alone is ignored by responsive sites), so the Desktop toggle
        // actually changes the rendered layout — and it persists across the tab's loads.
        let destination = navigationAction.request.url
        // Capture the main-frame navigation TARGET so webNavigation.onBeforeNavigate reports where the
        // navigation is GOING (webView.url still holds the previous committed page until didCommit).
        // Navigable schemes only; the userscript-install cancel below clears it.
        if navigationAction.targetFrame?.isMainFrame ?? true,
           let dest = destination, let scheme = dest.scheme?.lowercased(),
           ["http", "https", "about", "file", "data"].contains(scheme) {
            pendingNavTargets[ObjectIdentifier(webView)] = dest.absoluteString
        }
        let isStore = destination.map(Self.isChromeWebStoreURL) ?? false
        if let tab = tabManager.tabs.first(where: { $0.webView === webView }) {
            // Chrome Web Store pages only render their real "Add to Chrome" button (and skip the
            // "you're not on Chrome" banner) for a desktop Chrome client, so force that for store
            // hosts regardless of the tab's toggle; otherwise honor the user's Desktop choice.
            if isStore {
                preferences.preferredContentMode = .desktop
                webView.customUserAgent = Self.desktopChromeUserAgent
            } else {
                preferences.preferredContentMode = tab.prefersDesktop ? .desktop : .mobile
                // Clear the store UA when leaving the store (but don't clobber a manual Desktop UA).
                if webView.customUserAgent == Self.desktopChromeUserAgent {
                    webView.customUserAgent = tab.prefersDesktop ? Self.desktopSafariUserAgent : nil
                }
            }
            applyShields(to: tab, preferences: preferences, navigationAction: navigationAction, destination: destination, isStore: isStore)
        }
        if let url = navigationAction.request.url {
            // Open external app schemes (mailto:, tel:, etc.) via the system.
            if let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "file", "data"].contains(scheme),
               UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel, preferences)
                return
            }

            // One-tap userscript install: opening a *.user.js in the main frame shows the install
            // card instead of dumping raw JavaScript — the Tampermonkey/Greasemonkey behavior.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let scheme = url.scheme?.lowercased() ?? ""
            if isMainFrame,
               ["http", "https", "file"].contains(scheme),
               UserScriptInstaller.isUserScriptURL(url) {
                if viewSourceAllowOnce.remove(url) != nil {
                    decisionHandler(.allow, preferences)   // user picked "View source" — load as text
                    return
                }
                // Not navigating — hand the .user.js to an installed userscript manager that claims it
                // (Chrome behavior) or show BrownBear's native install card. Drop the captured target so
                // it can't be mis-consumed by the next navigation's onBeforeNavigate.
                pendingNavTargets.removeValue(forKey: ObjectIdentifier(webView))
                decisionHandler(.cancel, preferences)
                handleUserScriptInstall(for: url)
                return
            }
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // If WebKit can't render this response inline (a PDF, zip, dmg, or any binary asset), turn it
        // into a download instead of showing a blank page. Userscript *.user.js installs are already
        // intercepted in navigationAction, so they never reach here.
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        // begin() sets the delegate; the manager asks the user to confirm before any bytes are
        // written, and fires onDownloadStarted (→ the toast) only once a download actually begins.
        DownloadManager.shared.begin(download)
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.begin(download)
    }


    /// Present the install card for a userscript URL, with a "View source" escape that re-loads the
    /// raw file (allowed through the interceptor once). Internal because the WKUIDelegate
    /// (target="_blank" → install card) in the main controller file also calls it across files.
    func presentScriptInstall(for url: URL) {
        let installer = ScriptInstallViewController(
            url: url,
            onViewSource: { [weak self] sourceURL in
                guard let self else { return }
                self.viewSourceAllowOnce.insert(sourceURL)
                self.tabManager.activeTab?.load(sourceURL)
            })
        // Present on the top-most controller so the card still appears when a modal (the menu
        // action sheet, the dashboard) is already up — rather than silently swallowing the load.
        TopViewControllerPresenter.present(installer.wrappedForPresentation())
    }
}
