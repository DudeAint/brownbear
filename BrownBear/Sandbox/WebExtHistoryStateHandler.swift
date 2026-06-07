//
//  WebExtHistoryStateHandler.swift
//  BrownBear
//
//  Captures same-document history changes — history.pushState / replaceState and the popstate event —
//  so chrome.webNavigation.onHistoryStateUpdated can fire on iOS. WKWebView's navigation delegate does
//  NOT report same-document navigations (a SPA route change never hits didCommit/didFinish), so without
//  this hook a single-page app would look frozen to a webNavigation extension. The companion PAGE-world
//  user script (brownbear-webext-histstate.js) wraps the two History methods and listens for popstate,
//  posting the new URL here; this handler validates it and hands it to the browser, which resolves the
//  tab and calls WebExtensionEventEmitter.webNavHistoryStateUpdated (gated on the \"webNavigation\"
//  permission inside the runtime fan-out — see WebExtensionRuntime.dispatchEventToAll).
//
//  Trust: this runs in the untrusted PAGE world, so the handler performs NO privileged action. It only
//  forwards a main-frame URL string for an EVENT emission; it touches no storage, network, or grant.
//  Subframe and oversized payloads are dropped. The page can at most spoof its OWN history events, which
//  is exactly what a real same-document navigation looks like — no capability is gained.
//

import WebKit

/// The browser side that turns a captured history-state change into a chrome.webNavigation event.
/// BrownBearBrowserViewController conforms (it owns the tab registry + WebExtensionEventEmitter).
@MainActor
protocol WebExtHistoryStateDelegate: AnyObject {
    /// A same-document history change happened in `webView`'s main frame; `url` is the new location.
    func historyStateDidUpdate(in webView: WKWebView, url: String)
}

final class WebExtHistoryStateHandler: NSObject, WKScriptMessageHandler {

    static let handlerName = "brownbearWebextHistory"

    /// Set by the browser VC (via InjectionOrchestrator) so the captured event reaches the emitter.
    @MainActor weak var delegate: WebExtHistoryStateDelegate?

    private static let maxURLLength = 8192

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        // Same-document navigation is a top-level concept; ignore subframes (Chrome reports frame 0).
        guard message.frameInfo.isMainFrame else { return }
        guard let body = message.body as? [String: Any],
              let url = body["url"] as? String,
              !url.isEmpty, url.count <= Self.maxURLLength else { return }
        // Only http(s) same-document changes are meaningful webNavigation events; drop anything else so
        // a page can't inject about:/data:/javascript: URLs into the extension's navigation stream.
        guard let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let webView = message.webView
        Task { @MainActor in
            guard let webView else { return }
            self.delegate?.historyStateDidUpdate(in: webView, url: url)
        }
    }
}
