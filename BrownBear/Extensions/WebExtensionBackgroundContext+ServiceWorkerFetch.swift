//
//  WebExtensionBackgroundContext+ServiceWorkerFetch.swift
//  BrownBear
//
//  Service-worker FETCH interception. A real MV3 service worker can serve its OWN extension-scheme
//  requests from a `fetch` event handler — Stylus serves `chrome-extension://<id>/data?…` (the
//  per-frame client data its popup and content pages load as a script) entirely from the worker, never
//  from a packaged file. BrownBear's background is a headless JSContext, not a real service worker, so
//  WebKit never fires a fetch event against it. Instead `WebExtensionSchemeHandler`, when a request has
//  no packaged file, calls here to give the worker its chance: we invoke the shim's
//  `__bbDispatchFetch(url, method, headers, callback)` on the context's serial queue and decode the
//  worker's `respondWith` Response. A non-match (no fetch listener, or none responded) returns nil so
//  the scheme handler falls through to its normal not-found.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// A response synthesized by the worker's `fetch` handler.
    struct ServiceWorkerFetchResponse {
        let status: Int
        let statusText: String
        let headers: [String: String]
        let body: Data
    }

    /// Ask the worker's `fetch` handler to serve `urlString`. Runs entirely on the context's serial
    /// `queue` (the JSContext is not thread-safe). Returns nil when the worker doesn't claim the request
    /// — no fetch listener, none called `respondWith`, the worker is gone, or it never settled within the
    /// safety window (a stuck handler must not wedge the page's resource load).
    func serviceWorkerFetch(urlString: String, method: String, headersJSON: String) async -> ServiceWorkerFetchResponse? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ServiceWorkerFetchResponse?, Never>) in
            queue.async { [weak self] in
                guard let self, self.isAlive, let context = self.context,
                      let dispatch = context.objectForKeyedSubscript("__bbDispatchFetch"),
                      !dispatch.isUndefined, !dispatch.isNull else {
                    continuation.resume(returning: nil)
                    return
                }
                // resume EXACTLY once. The JS callback and the timeout both run on `queue` (serial), so a
                // plain flag is race-free — no lock needed.
                var resumed = false
                let finish: (ServiceWorkerFetchResponse?) -> Void = { result in
                    if resumed { return }
                    resumed = true
                    continuation.resume(returning: result)
                }
                let callback: @convention(block) (String) -> Void = { json in
                    finish(WebExtensionBackgroundContext.decodeServiceWorkerFetch(json))
                }
                dispatch.call(withArguments: [urlString, method, headersJSON, callback])
                // Safety net: a fetch handler that never settles (e.g. an awaited read that hangs) must
                // not block the page load forever — give up and let the scheme handler 404.
                self.queue.asyncAfter(deadline: .now() + 8) { finish(nil) }
            }
        }
    }

    /// Decode the shim's `__bbDispatchFetch` result JSON. `{matched:false}` (or anything malformed) → nil.
    private static func decodeServiceWorkerFetch(_ json: String) -> ServiceWorkerFetchResponse? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["matched"] as? Bool) == true else {
            return nil
        }
        let status = (object["status"] as? Int) ?? 200
        let statusText = (object["statusText"] as? String) ?? ""
        var headers: [String: String] = [:]
        if let rawHeaders = object["headers"] as? [String: Any] {
            for (key, value) in rawHeaders { headers[key] = "\(value)" }
        }
        var body = Data()
        if let base64 = object["bodyBase64"] as? String, !base64.isEmpty,
           let decoded = Data(base64Encoded: base64) {
            body = decoded
        }
        return ServiceWorkerFetchResponse(status: status, statusText: statusText, headers: headers, body: body)
    }
}
