//
//  WebExtensionMessageRouter+Inject.swift
//  BrownBear
//
//  The two tokenless MAIN-world injection handlers, split out of the main router's `route()` dispatcher so
//  that switch stays under SwiftLint's body/complexity limits.
//
//  - page.injectMainWorld: an MV3 world:"MAIN" manager (ScriptCat's inject.js + the cross-world bridge shim).
//  - injectWarScript: a content script's web-accessible `<script src=chrome.runtime.getURL('x.js')>` helper.
//    On a strict-CSP site the page refuses both the script subresource (script-src) AND a content-world
//    fetch of it (connect-src → "Load failed" on YouTube/GitHub). Chrome exempts web_accessible_resources
//    from the page CSP; we replicate it natively by reading the declared file + evaluating it MAIN-world.
//
//  Both rely on the fact that native `evaluateJavaScript` into the page world is NOT subject to the page's
//  CSP. Only our isolated content world can reach these (a page script can't post to the handler); the
//  sending web view/frame is the trust anchor.
//

import WebKit

extension WebExtensionMessageRouter {

    /// Dispatch the two MAIN-world injection APIs, or nil if `api` is neither (so `route()` continues).
    func handleMainWorldInjection(api: String, payload: [String: Any],
                                  webView: WKWebView?, frameInfo: WKFrameInfo?) async -> Any? {
        switch api {
        case "page.injectMainWorld":
            if let webView, let code = payload["code"] as? String, !code.isEmpty {
                await evaluateInPageWorld(code, webView: webView, frameInfo: frameInfo)
            }
            return NSNull()
        case "injectWarScript":
            return await injectWebAccessibleScript(payload: payload, webView: webView, frameInfo: frameInfo)
        default:
            return nil
        }
    }

    /// Evaluate `code` in the page MAIN world (CSP-immune) and return only AFTER the eval completes — so a
    /// caller (the WAR-script bridge) can sequence a diverted script's synthetic `load` on real execution.
    private func evaluateInPageWorld(_ code: String, webView: WKWebView, frameInfo: WKFrameInfo?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: (Any?, Error?) -> Void = { _, _ in continuation.resume() }
            if let frameInfo {
                BBEvaluateJavaScriptInFrameForResult(webView, code, frameInfo, .page, done)
            } else {
                BBEvaluateJavaScriptForResult(webView, code, .page, done)
            }
        }
    }

    /// Wrap injected code to run with the extension's chrome (its content session's runInjected), or return
    /// it unchanged when there's no content session in the frame (raw eval, no chrome — as before). Native
    /// routes content-world executeScript code through this so a re-injected content.js sees `chrome`.
    func injectionCode(_ code: String, token: String?) -> String {
        guard let token else { return code }
        return "window.__bbExtContent['\(token)'].runInjected(\(Self.encodeJSONForJS(code)))"
    }

    /// Read + run a content script's web-accessible `<script src>` resource in the page MAIN world. Gated
    /// exactly like the WAR scheme handler: an ENABLED extension's DECLARED `web_accessible_resources`
    /// entry, traversal-free, whose `matches` allow the requesting page. Returns `{found:true}` once the
    /// eval completes (the JS bridge sequences the script's synthetic `load` on it), or `{found:false}` when
    /// the URL isn't a served resource (→ the bridge fires `error`).
    private func injectWebAccessibleScript(payload: [String: Any],
                                           webView: WKWebView?,
                                           frameInfo: WKFrameInfo?) async -> Any {
        guard let webView, let urlString = payload["url"] as? String, let url = URL(string: urlString),
              let host = url.host, ChromeWebStore.isExtensionID(host) else { return ["found": false] }
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        let pageURL = webView.url?.absoluteString
        guard WebExtensionWARSchemeHandler.isTraversalFree(path),
              let ext = await store.ext(for: host), ext.enabled, let manifest = ext.manifest,
              WebExtensionWARSchemeHandler.isWebAccessible(path: path, pageURL: pageURL, manifest: manifest),
              let data = store.fileSync(extensionID: host, path: path),
              let code = String(data: data, encoding: .utf8), !code.isEmpty else {
            return ["found": false]
        }
        await evaluateInPageWorld(code, webView: webView, frameInfo: frameInfo)
        return ["found": true]
    }
}
