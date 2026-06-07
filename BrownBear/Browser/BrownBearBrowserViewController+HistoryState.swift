//
//  BrownBearBrowserViewController+HistoryState.swift
//  BrownBear
//
//  Turns same-document (SPA) history changes captured by the PAGE-world hook into
//  chrome.webNavigation.onHistoryStateUpdated events. Split out of the main controller to keep it under
//  the SwiftLint file-length limit; reaches `extTabId(for:)` and `webExtEvents` (internal).
//

import WebKit

extension BrownBearBrowserViewController: WebExtHistoryStateDelegate {
    /// A same-document history change (pushState/replaceState/popstate) was captured in `webView`'s main
    /// frame by the PAGE-world hook. WKWebView's navigation delegate never reports these, so this is the
    /// only signal for SPA route changes — turn it into the webNavigation event for the backing tab.
    /// The runtime gates delivery on each extension's "webNavigation" permission.
    func historyStateDidUpdate(in webView: WKWebView, url: String) {
        guard let id = extTabId(for: webView) else { return }
        webExtEvents.webNavHistoryStateUpdated(extTabId: id, url: url)
    }
}
