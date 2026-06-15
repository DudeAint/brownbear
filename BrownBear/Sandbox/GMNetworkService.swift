//
//  GMNetworkService.swift
//  BrownBear
//
//  Powers GM_xmlhttpRequest. Requests run on a native URLSession so they bypass the page's CORS
//  restrictions — the whole point of the API — and stream lifecycle events (loadstart, progress,
//  readystatechange, load/error/timeout, loadend) back to the script. Because the bridge can't
//  carry binary, arraybuffer/blob responses are base64-encoded and reconstructed in JS.
//
//  Security (CLAUDE.md §5.2): every request is gated by the script's @connect allowlist; a host
//  the script didn't declare is refused before any socket is opened.
//

import Foundation

/// A parsed GM_xmlhttpRequest. Built from the JS payload dictionary.
struct GMXHRRequest {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
    let responseType: String   // "" | "text" | "json" | "arraybuffer" | "blob" | "document"
    let timeout: TimeInterval?
    let anonymous: Bool
    /// Tampermonkey/Violentmonkey `overrideMimeType`: forces how the response body is interpreted.
    /// Its main use is the `text/plain; charset=x-user-defined` trick to read a binary response as a
    /// byte-preserving string via `responseText`. nil when the script didn't set it.
    let overrideMimeType: String?

    init?(payload: [String: Any]) {
        guard let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
            return nil
        }
        self.url = url
        self.method = (payload["method"] as? String)?.uppercased() ?? "GET"
        self.headers = (payload["headers"] as? [String: String]) ?? [:]
        if let bodyString = payload["data"] as? String {
            // A binary request body (ArrayBuffer/typed array) crosses the bridge base64-encoded; decode it
            // back to the exact bytes. A malformed base64 string fails closed to no body rather than
            // smuggling the literal base64 text as the payload.
            if payload["dataIsBase64"] as? Bool == true {
                self.body = Data(base64Encoded: bodyString)
            } else {
                self.body = bodyString.data(using: .utf8)
            }
        } else {
            self.body = nil
        }
        self.responseType = (payload["responseType"] as? String) ?? ""
        if let timeoutMs = payload["timeout"] as? Double, timeoutMs > 0 {
            self.timeout = timeoutMs / 1000.0
        } else {
            self.timeout = nil
        }
        self.anonymous = (payload["anonymous"] as? Bool) ?? false
        if let omt = (payload["overrideMimeType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !omt.isEmpty {
            self.overrideMimeType = omt
        } else {
            self.overrideMimeType = nil
        }
    }

    /// The response body must be delivered as raw bytes (not UTF-8 text) when the script asked for an
    /// arraybuffer/blob, OR when `overrideMimeType` forces byte-preserving decoding — the
    /// `charset=x-user-defined` binary-string trick, or any non-text MIME.
    var wantsBinary: Bool { responseType == "arraybuffer" || responseType == "blob" }

    /// `overrideMimeType` forces a byte-preserving `responseText` (responseType is text/empty, but the
    /// override marks the payload as binary). Distinct from `wantsBinary`, which delivers via `response`.
    var overrideForcesBinaryText: Bool {
        guard !wantsBinary, let mime = overrideMimeType?.lowercased() else { return false }
        if mime.contains("x-user-defined") { return true }
        if mime.hasPrefix("text/") { return false }
        if mime.contains("json") || mime.contains("xml") || mime.contains("html")
            || mime.contains("javascript") || mime.contains("urlencoded") { return false }
        return true
    }
}

/// Shared across the @MainActor router and its own background URLSession delegate queue; all
/// mutable state is guarded by `lock`, hence `@unchecked Sendable`.
final class GMNetworkService: NSObject, @unchecked Sendable {

    /// Per-request mutable state, accessed only behind `lock`.
    private final class Context {
        let requestID: String
        let request: GMXHRRequest
        /// The script's @connect allowlist + page host — re-checked on every redirect hop.
        let connects: [String]
        let pageHost: String?
        let emit: (String, [String: Any]) -> Void
        /// The originating userscript's name, for the Network inspector row.
        let scriptName: String?
        /// When the request started, for the duration shown in the Network inspector.
        let startedAt: Date
        var received = Data()
        var response: HTTPURLResponse?
        var expectedLength: Int64 = -1
        init(requestID: String, request: GMXHRRequest, connects: [String], pageHost: String?,
             scriptName: String?, startedAt: Date, emit: @escaping (String, [String: Any]) -> Void) {
            self.requestID = requestID
            self.request = request
            self.connects = connects
            self.pageHost = pageHost
            self.scriptName = scriptName
            self.startedAt = startedAt
            self.emit = emit
        }
    }

    /// Set by the orchestrator to mirror each completed request into the Network inspector. Called once
    /// per request from the URLSession delegate queue (off the main actor); the sink hops to its actor.
    var networkLogger: (@Sendable (NetworkLogEntry) -> Void)?

    /// Cap on the response text kept for the Network inspector's Response block (16 KB) — enough to read,
    /// bounded so a large download can't bloat the in-memory log.
    static let maxLoggedResponseBytes = 16_384

    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]          // sessionTask.taskIdentifier → context
    private var taskByRequestID: [String: URLSessionTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    // MARK: - API

    /// Validate and start a request. `emit(eventType, payload)` is called for each lifecycle
    /// event. If `@connect` doesn't permit the host, emits a single `error` and returns.
    func start(requestID: String,
               payload: [String: Any],
               connects: [String],
               pageHost: String?,
               scriptName: String? = nil,
               emit: @escaping (String, [String: Any]) -> Void) {
        guard let request = GMXHRRequest(payload: payload) else {
            emit("error", ["error": "invalid request", "readyState": 4])
            emit("loadend", ["readyState": 4])
            return
        }
        guard Self.isConnectAllowed(host: request.url.host, connects: connects, pageHost: pageHost) else {
            emit("error", ["error": "@connect does not permit \(request.url.host ?? "host")", "readyState": 4])
            emit("loadend", ["readyState": 4])
            return
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        if request.anonymous { urlRequest.httpShouldHandleCookies = false }

        let task = session.dataTask(with: urlRequest)
        let context = Context(requestID: requestID, request: request,
                              connects: connects, pageHost: pageHost,
                              scriptName: scriptName, startedAt: Date(), emit: emit)
        lock.lock()
        contexts[task.taskIdentifier] = context
        taskByRequestID[requestID] = task
        lock.unlock()

        emit("loadstart", ["readyState": 1])
        task.resume()
    }

    /// Cancel an in-flight request; emits `abort` + `loadend` exactly once. The context is
    /// removed under the lock so a concurrent didCompleteWithError can't also emit terminals.
    func abort(requestID: String) {
        lock.lock()
        let task = taskByRequestID.removeValue(forKey: requestID)
        let context = task.flatMap { contexts.removeValue(forKey: $0.taskIdentifier) }
        lock.unlock()
        task?.cancel()
        guard let context else { return }   // already completed — don't double-emit
        context.emit("abort", ["readyState": 4])
        context.emit("loadend", ["readyState": 4])
    }

    // MARK: - @connect allowlist

    /// Mirrors Tampermonkey semantics: a request is allowed when the host matches a declared
    /// @connect domain (or a subdomain of it), `@connect *`, `@connect self`/`localhost`, or
    /// the request targets the page's own host.
    static func isConnectAllowed(host: String?, connects: [String], pageHost: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if let pageHost = pageHost?.lowercased(), host == pageHost { return true }
        for entry in connects {
            let token = entry.lowercased().trimmingCharacters(in: .whitespaces)
            if token == "*" { return true }
            if token == "self", let pageHost = pageHost?.lowercased(), host == pageHost { return true }
            if token == "localhost" && (host == "localhost" || host.hasSuffix(".localhost")) { return true }
            if token.isEmpty { continue }
            if host == token || host.hasSuffix("." + token) { return true }
        }
        return false
    }

    // MARK: - Response assembly

    private func finishResponsePayload(_ context: Context) -> [String: Any] {
        let http = context.response
        let status = http?.statusCode ?? 0
        let headersString = Self.formatHeaders(http)
        var payload: [String: Any] = [
            "readyState": 4,
            "status": status,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: status),
            "responseHeaders": headersString,
            "finalUrl": http?.url?.absoluteString ?? context.request.url.absoluteString,
            "responseType": context.request.responseType,
            "loaded": context.received.count,
            "total": Int(max(context.expectedLength, Int64(context.received.count))),
            "lengthComputable": context.expectedLength >= 0
        ]
        // contentType the client can use for a Blob's `type`: the script's overrideMimeType wins, else the
        // response's actual Content-Type.
        if let override = context.request.overrideMimeType {
            payload["contentType"] = override
        } else if let ct = http?.value(forHTTPHeaderField: "Content-Type") {
            payload["contentType"] = ct
        }
        if context.request.wantsBinary {
            payload["isBase64"] = true
            payload["response"] = context.received.base64EncodedString()
            payload["responseText"] = ""
        } else if context.request.overrideForcesBinaryText {
            // overrideMimeType (x-user-defined / non-text MIME): responseText is a byte-preserving string
            // (one char per byte, charCodeAt 0-255) so the script can read the raw bytes the TM/VM way.
            let binaryText = Self.binaryString(context.received)
            payload["isBase64"] = false
            payload["responseText"] = binaryText
            payload["response"] = binaryText
        } else {
            let text = String(data: context.received, encoding: .utf8) ?? ""
            payload["isBase64"] = false
            payload["responseText"] = text
            payload["response"] = text
        }
        return payload
    }

    /// Build a byte-preserving "binary string": each byte becomes one character with that code point
    /// (0-255), matching the JS string a userscript reads from `responseText` under
    /// `overrideMimeType: 'text/plain; charset=x-user-defined'`. Crosses the JSON bridge intact.
    private static func binaryString(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }

    private static func formatHeaders(_ response: HTTPURLResponse?) -> String {
        guard let response else { return "" }
        return response.allHeaderFields
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\r\n")
    }
}

// MARK: - URLSessionDataDelegate

extension GMNetworkService: URLSessionDataDelegate {

    /// Re-validate every HTTP redirect against the script's @connect allowlist. Without this,
    /// URLSession silently follows a 3xx to ANY host — letting a declared host bounce the request
    /// (and its response) to an undeclared one, defeating the allowlist entirely (SSRF). A refused
    /// redirect returns the 3xx body to the script rather than fetching the disallowed target.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let context = contexts[task.taskIdentifier]
        lock.unlock()
        guard let context,
              Self.isConnectAllowed(host: request.url?.host, connects: context.connects, pageHost: context.pageHost) else {
            completionHandler(nil)   // refuse the redirect; the 3xx response stands
            return
        }
        completionHandler(GMRedirectGuard.stripSensitiveHeadersIfCrossHost(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let context = contexts[dataTask.taskIdentifier]
        context?.response = response as? HTTPURLResponse
        context?.expectedLength = response.expectedContentLength
        lock.unlock()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        context?.emit("readystatechange", ["readyState": 2, "status": status])
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let context = contexts[dataTask.taskIdentifier] else { lock.unlock(); return }
        context.received.append(data)
        let loaded = context.received.count
        let total = Int(max(context.expectedLength, Int64(loaded)))
        let computable = context.expectedLength >= 0
        lock.unlock()
        context.emit("progress", ["readyState": 3, "loaded": loaded,
                                   "total": total, "lengthComputable": computable])
        context.emit("readystatechange", ["readyState": 3])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let context = contexts.removeValue(forKey: task.taskIdentifier)
        if let requestID = context?.requestID { taskByRequestID.removeValue(forKey: requestID) }
        lock.unlock()
        guard let context else { return }

        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }   // abort() already emitted
            if error.code == NSURLErrorTimedOut {
                context.emit("timeout", ["readyState": 4, "error": error.localizedDescription])
            } else {
                context.emit("error", ["readyState": 4, "error": error.localizedDescription])
            }
            context.emit("loadend", ["readyState": 4])
            recordNetworkLog(context, status: 0, error: error.localizedDescription)
            return
        }

        let payload = finishResponsePayload(context)
        context.emit("readystatechange", payload)
        context.emit("load", payload)
        context.emit("loadend", payload)
        recordNetworkLog(context, status: context.response?.statusCode ?? 0, error: nil)
    }

    /// Mirror a completed GM_xmlhttpRequest into the Network inspector. No-op when no sink is attached.
    private func recordNetworkLog(_ context: Context, status: Int, error: String?) {
        guard let logger = networkLogger else { return }
        let request = context.request
        let body = request.body.flatMap { String(data: $0.prefix(4096), encoding: .utf8) }
        // Decode the response as text for the inspector's Response block; a binary response (image/zip)
        // won't decode and is left nil. Bounded so a big download can't bloat the in-memory log.
        let responseBody = String(data: context.received.prefix(Self.maxLoggedResponseBytes), encoding: .utf8)
        let entry = NetworkLogEntry(
            createdAt: context.startedAt,
            kind: .gmXHR,
            method: request.method,
            url: request.url.absoluteString,
            statusCode: status,
            scriptName: context.scriptName,
            durationMs: Int(Date().timeIntervalSince(context.startedAt) * 1000),
            requestHeaders: request.headers,
            responseHeaders: Self.headerDictionary(context.response),
            requestBody: body,
            responseBytes: context.received.count,
            responseBody: responseBody,
            error: error)
        logger(entry)
    }

    /// Flatten an HTTPURLResponse's header fields to `[String: String]` for the Network detail view.
    private static func headerDictionary(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            out[String(describing: key)] = String(describing: value)
        }
        return out
    }
}

// MARK: - Redirect guard (shared with the headless background path)

/// A per-task `URLSessionTaskDelegate` that re-validates HTTP redirects against a script's @connect
/// allowlist. The headless runner (which uses completion-handler tasks on a delegate-less session)
/// attaches one of these per task; GMNetworkService re-implements the same check inline against its
/// per-request context. Either way, a redirect to an undeclared host is refused.
final class GMRedirectGuard: NSObject, URLSessionTaskDelegate {

    private let connects: [String]
    private let pageHost: String?

    init(connects: [String], pageHost: String?) {
        self.connects = connects
        self.pageHost = pageHost
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard GMNetworkService.isConnectAllowed(host: request.url?.host, connects: connects, pageHost: pageHost) else {
            completionHandler(nil)
            return
        }
        completionHandler(Self.stripSensitiveHeadersIfCrossHost(request, from: task.originalRequest))
    }

    /// Strip credentials when a redirect crosses to a different host, matching browser fetch
    /// semantics (Foundation already strips Authorization cross-origin; we also drop Cookie).
    static func stripSensitiveHeadersIfCrossHost(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        guard let originalHost = original?.url?.host?.lowercased(),
              originalHost != request.url?.host?.lowercased() else { return request }
        var stripped = request
        for field in ["Authorization", "Cookie", "Proxy-Authorization"] {
            stripped.setValue(nil, forHTTPHeaderField: field)
        }
        return stripped
    }
}
