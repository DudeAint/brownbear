//
//  WebExtensionBackgroundContext+Fetch.swift
//  BrownBear
//
//  A native-backed `fetch` for the extension background worker's JSContext. Service workers (and the
//  MV2 background scripts ScriptCat-derived extensions ship) lean on `fetch` heavily; JavaScriptCore
//  has none, so they throw "undefined is not an object (evaluating '…fetch.bind')". We proxy the
//  request through URLSession and hand the JS shim a serialized response it wraps in a Response object.
//
//  Security (CLAUDE.md §5 — every JS→native boundary is an untrusted trust boundary, gate host-reaching
//  APIs, fail closed):
//   • http(s) requests are gated on the extension's host_permissions (the SAME effective-host matcher
//     chrome.cookies uses). This mirrors Chrome's model: a service worker may fetch a host in its
//     host_permissions without CORS; everything else fails closed here rather than becoming an open
//     native SSRF/exfiltration proxy.
//   • chrome-extension:// requests resolve ONLY against this extension's own packaged files (via the
//     store's contained, nonisolated read) — never another extension's, never the filesystem.
//   • Any other scheme (file:, data:, ftp:, …) is rejected.
//   • Request/response bodies are treated as opaque bytes; nothing is evaluated.
//
//  Split into its own file purely so WebExtensionBackgroundContext stays under the length limit; it
//  uses `callBack`/`jsonString` (internal) + `cookieHostMatcher`/`extensionID` + the public store.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// Max response body we buffer back into JS, so a runaway download can't exhaust the JSContext heap.
    private static let maxFetchResponseBytes = 32 * 1024 * 1024

    func installFetchNative(into context: JSContext) {
        let extensionID = self.extensionID
        // requestJSON: { url, method, headers: {k:v}, body: String?, bodyEncoding: "utf8"|"base64" }
        // callback(resultJSON) where resultJSON is the serialized response (see makeFetchResult).
        let fetch: @convention(block) (String, JSValue) -> Void = { [weak self] requestJSON, callback in
            guard let self else { return }
            let req = ((try? JSONSerialization.jsonObject(with: Data(requestJSON.utf8))) as? [String: Any]) ?? [:]
            let urlString = (req["url"] as? String) ?? ""
            guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
                self.callBack(callback, with: Self.fetchError("invalid URL"))
                return
            }

            switch scheme {
            case "http", "https":
                guard self.cookieHostMatcher(urlString) else {
                    self.callBack(callback, with: Self.fetchError(
                        "no host permission for \(url.host ?? urlString) — declare it in host_permissions"))
                    return
                }
                self.performHTTPFetch(url: url, req: req, callback: callback)
            case "chrome-extension", "moz-extension":
                self.performPackagedFetch(url: url, extensionID: extensionID, callback: callback)
            default:
                self.callBack(callback, with: Self.fetchError("unsupported scheme: \(scheme)"))
            }
        }
        context.setObject(fetch, forKeyedSubscript: "__bb_fetch" as NSString)
    }

    // MARK: - http(s)

    private func performHTTPFetch(url: URL, req: [String: Any], callback: JSValue) {
        var request = URLRequest(url: url)
        request.httpMethod = (req["method"] as? String)?.uppercased() ?? "GET"
        request.timeoutInterval = 60
        if let headers = req["headers"] as? [String: Any] {
            WebExtensionFetchSecurity.apply(headers: headers, to: &request)   // drops CRLF / invalid names
        }
        if let body = req["body"] as? String {
            if (req["bodyEncoding"] as? String) == "base64" {
                request.httpBody = Data(base64Encoded: body)
            } else {
                request.httpBody = body.data(using: .utf8)
            }
        }
        // Redirect-guarded session: the host_permissions gate above only saw the initial URL, so a
        // permitted host must not 30x-redirect onto an undeclared/internal host (SSRF). Invalidate after.
        let session = WebExtensionFetchSecurity.redirectGuardedSession(hostPatterns: cookieHostPatterns)
        let loggedMethod = request.httpMethod ?? "GET"
        let loggedURL = url.absoluteString
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            if let error {
                self.recordNetworkLog(method: loggedMethod, url: loggedURL, status: 0, bytes: nil,
                                      error: error.localizedDescription)
                self.callBack(callback, with: Self.fetchError(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.recordNetworkLog(method: loggedMethod, url: loggedURL, status: 0, bytes: nil,
                                      error: "no HTTP response")
                self.callBack(callback, with: Self.fetchError("no HTTP response"))
                return
            }
            var body = data
            if let d = data, d.count > Self.maxFetchResponseBytes {
                body = Data(d.prefix(Self.maxFetchResponseBytes))   // clamp so a huge download can't OOM JSC
            }
            var headerMap: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headerMap[String(describing: key).lowercased()] = String(describing: value)
            }
            self.recordNetworkLog(method: loggedMethod, url: loggedURL, status: http.statusCode,
                                  bytes: data?.count,
                                  responseBody: data.flatMap {
                                      String(data: $0.prefix(GMNetworkService.maxLoggedResponseBytes),
                                             encoding: .utf8)
                                  },
                                  error: nil)
            self.callBack(callback, with: self.makeFetchResult(
                status: http.statusCode,
                statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                finalURL: http.url?.absoluteString ?? url.absoluteString,
                headers: headerMap,
                body: body))
        }
        task.resume()
    }

    /// Mirror a service-worker / background `fetch` into the Logs → Network inspector. Fire-and-forget so
    /// it never delays the worker's response; tagged with the extension's name as the request's source.
    private func recordNetworkLog(method: String, url: String, status: Int, bytes: Int?,
                                  responseBody: String? = nil, error: String?) {
        let extensionID = self.extensionID
        Task {
            let name = await BrownBearServices.shared.webExtensionStore.ext(for: extensionID)?.displayName
            await BrownBearServices.shared.networkLogStore.append(
                NetworkLogEntry(kind: .hostFetch, method: method, url: url, statusCode: status,
                                scriptName: name, responseBytes: bytes,
                                responseBody: responseBody, error: error))
        }
    }

    // MARK: - chrome-extension:// (own packaged resources)

    private func performPackagedFetch(url: URL, extensionID: String, callback: JSValue) {
        // chrome-extension://<id>/<path> — only THIS extension's own package.
        guard let host = url.host, host == extensionID else {
            callBack(callback, with: Self.fetchError("cross-extension fetch is not allowed"))
            return
        }
        let path = url.path
        guard let data = BrownBearServices.shared.webExtensionStore.fileSync(extensionID: extensionID, path: path) else {
            callBack(callback, with: makeFetchResult(status: 404, statusText: "Not Found",
                                                     finalURL: url.absoluteString, headers: [:], body: nil))
            return
        }
        let contentType = Self.mimeType(forPath: path)
        callBack(callback, with: makeFetchResult(status: 200, statusText: "OK",
                                                 finalURL: url.absoluteString,
                                                 headers: ["content-type": contentType], body: data))
    }

    // MARK: - Result marshaling

    /// Build the serialized response the JS shim wraps in a Response. The body is base64 (binary-safe);
    /// the JS side decodes it for text()/json()/arrayBuffer().
    private func makeFetchResult(status: Int, statusText: String, finalURL: String,
                                 headers: [String: String], body: Data?) -> String {
        let payload: [String: Any] = [
            "ok": (200...299).contains(status),
            "status": status,
            "statusText": statusText,
            "url": finalURL,
            "headers": headers,
            "bodyBase64": body?.base64EncodedString() ?? "",
            "error": NSNull()
        ]
        return jsonString(payload)
    }

    private static func fetchError(_ message: String) -> String {
        let payload: [String: Any] = [
            "ok": false, "status": 0, "statusText": "", "url": "",
            "headers": [String: String](), "bodyBase64": "", "error": message
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{\"ok\":false,\"status\":0,\"error\":\"fetch failed\"}"
    }

    private static func mimeType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "json": return "application/json"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html", "htm": return "text/html"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
