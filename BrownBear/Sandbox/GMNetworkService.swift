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

    init?(payload: [String: Any]) {
        guard let urlString = payload["url"] as? String, let url = URL(string: urlString) else {
            return nil
        }
        self.url = url
        self.method = (payload["method"] as? String)?.uppercased() ?? "GET"
        self.headers = (payload["headers"] as? [String: String]) ?? [:]
        if let bodyString = payload["data"] as? String {
            self.body = bodyString.data(using: .utf8)
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
    }

    var wantsBinary: Bool { responseType == "arraybuffer" || responseType == "blob" }
}

/// Shared across the @MainActor router and its own background URLSession delegate queue; all
/// mutable state is guarded by `lock`, hence `@unchecked Sendable`.
final class GMNetworkService: NSObject, @unchecked Sendable {

    /// Per-request mutable state, accessed only behind `lock`.
    private final class Context {
        let requestID: String
        let request: GMXHRRequest
        let emit: (String, [String: Any]) -> Void
        var received = Data()
        var response: HTTPURLResponse?
        var expectedLength: Int64 = -1
        init(requestID: String, request: GMXHRRequest, emit: @escaping (String, [String: Any]) -> Void) {
            self.requestID = requestID
            self.request = request
            self.emit = emit
        }
    }

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
        let context = Context(requestID: requestID, request: request, emit: emit)
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
        if context.request.wantsBinary {
            payload["isBase64"] = true
            payload["response"] = context.received.base64EncodedString()
            payload["responseText"] = ""
        } else {
            let text = String(data: context.received, encoding: .utf8) ?? ""
            payload["isBase64"] = false
            payload["responseText"] = text
            payload["response"] = text
        }
        return payload
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
            return
        }

        let payload = finishResponsePayload(context)
        context.emit("readystatechange", payload)
        context.emit("load", payload)
        context.emit("loadend", payload)
    }
}
