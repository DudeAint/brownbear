//
//  WebExtensionBackgroundContext+WebRequest.swift
//  BrownBear
//
//  webRequest dispatch INTO a worker's JSContext, split out of WebExtensionBackgroundContext.swift to keep
//  that file under the SwiftLint length limit. Two uses:
//    1. the `.user.js` install hand-off to a webRequest-based userscript manager (Violentmonkey) — a
//       synthetic onBeforeRequest + a webNavigation sequence so the manager runs its own confirm/install;
//    2. BLOCKING webRequest on FRAME navigations — the one request class WKWebView lets us intercept
//       (WKNavigationDelegate) — so an MV2 ad-blocker can block ad iframes / redirect-trackers.
//  `queue`/`isAlive`/`context`/`dispatchExtEvent`/`jsonString` are internal (not private) so this
//  same-module extension reaches them.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// Dispatch a synthetic `webRequest.onBeforeRequest` for a main-frame `.user.js` URL into this worker,
    /// so a webRequest-based userscript manager (Violentmonkey) runs its OWN install/confirm flow (fetch +
    /// cache + open its confirm page). Returns whether a matching onBeforeRequest listener was invoked —
    /// the webRequest analog of the declarativeNetRequest hand-off used for MV3 managers.
    func dispatchUserScriptWebRequest(url: String, tabId: Int) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                guard isAlive, let context else { continuation.resume(returning: false); return }
                context.setObject(url, forKeyedSubscript: "__bbPendingUserScriptURL" as NSString)
                context.setObject(tabId, forKeyedSubscript: "__bbPendingUserScriptTabId" as NSString)
                let result = context.evaluateScript(
                    "(typeof __bbDispatchWebRequestUserScript === 'function')"
                    + " ? !!__bbDispatchWebRequestUserScript(__bbPendingUserScriptURL, __bbPendingUserScriptTabId) : false")
                continuation.resume(returning: result?.toBool() ?? false)
            }
        }
    }

    /// Run this worker's BLOCKING webRequest.onBeforeRequest listeners for a FRAME navigation (the one
    /// request class WKWebView lets us intercept) and return the decision JSON the worker produced:
    /// `{"cancel":true}`, `{"redirectUrl":"…"}`, or `""` (allow). Lets an MV2 webRequest blocker block ad
    /// iframes / redirect-trackers; static subresources have no WebKit hook (declarativeNetRequest covers
    /// those). `type` is `"main_frame"` or `"sub_frame"`.
    func webRequestNavDecision(url: String, type: String, tabId: Int) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.async { [self] in
                guard isAlive, let context else { continuation.resume(returning: ""); return }
                context.setObject(url, forKeyedSubscript: "__bbPendingWRUrl" as NSString)
                context.setObject(type, forKeyedSubscript: "__bbPendingWRType" as NSString)
                context.setObject(tabId, forKeyedSubscript: "__bbPendingWRTab" as NSString)
                let result = context.evaluateScript(
                    "(typeof __bbWebRequestNavDecision === 'function')"
                    + " ? String(__bbWebRequestNavDecision(__bbPendingWRUrl, __bbPendingWRType, __bbPendingWRTab) || '') : ''")
                continuation.resume(returning: result?.toString() ?? "")
            }
        }
    }

    /// Fire a synthetic `webNavigation` sequence (onBeforeNavigate → onCommitted → onCompleted) for a
    /// `.user.js` main-frame navigation into THIS worker, with a REAL tab id. The webRequest twin above
    /// covers managers that install from `onBeforeRequest` (Violentmonkey); this covers managers that
    /// detect the install from `webNavigation` instead — notably Tampermonkey, whose default
    /// `scriptUrlDetection: "auto"` ignores the webRequest path and watches `onCommitted`. Generic: any
    /// manager listening on either channel runs its own confirm/install flow. No-op (early-returns inside
    /// the manager) if its detector can't resolve the tab, so it never makes things worse.
    func dispatchUserScriptWebNavigation(url: String, tabId: Int) {
        let base: [String: Any] = ["tabId": tabId, "url": url, "frameId": 0,
                                   "parentFrameId": -1, "processId": 0, "timeStamp": 0]
        var committed = base
        committed["transitionType"] = "link"
        committed["transitionQualifiers"] = [String]()
        dispatchExtEvent(name: "webNavigation.onBeforeNavigate", argsJSON: jsonString([base]))
        dispatchExtEvent(name: "webNavigation.onCommitted", argsJSON: jsonString([committed]))
        dispatchExtEvent(name: "webNavigation.onCompleted", argsJSON: jsonString([base]))
    }

    /// Detection-only: does this worker have a main-frame `webRequest.onBeforeRequest` listener whose
    /// filter matches `url`? Used to list the extension as an install TARGET without invoking the listener.
    func hasUserScriptWebRequestListener(url: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                guard isAlive, let context else { continuation.resume(returning: false); return }
                context.setObject(url, forKeyedSubscript: "__bbPendingUserScriptURL" as NSString)
                let result = context.evaluateScript(
                    "(typeof __bbHasWebRequestUserScriptListener === 'function')"
                    + " ? !!__bbHasWebRequestUserScriptListener(__bbPendingUserScriptURL) : false")
                continuation.resume(returning: result?.toBool() ?? false)
            }
        }
    }
}
