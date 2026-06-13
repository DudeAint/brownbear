//
//  NetworkLogHandler.swift
//  BrownBear
//
//  Receives the page-world network reporter's (brownbear-network-logger.js) per-request records and folds
//  them into the NetworkLogStore for the Logs → Network inspector. Registered in BOTH the page world and the
//  isolated content world (so page scripts, userscripts, and extension content scripts are all covered).
//  Untrusted page-world input: every field is validated and bounded; a malformed record is dropped, never
//  crashes. This handler does no privileged work — it only records a request the page already made.
//

import Foundation
import WebKit

/// The reply-less message handler behind `window.webkit.messageHandlers.brownbearNetLog`.
final class NetworkLogHandler: NSObject, WKScriptMessageHandler {

    static let handlerName = "brownbearNetLog"

    private let store: NetworkLogStore
    /// A request URL longer than this is truncated — a data: URL can be megabytes and has no inspector value.
    private static let maxURLLength = 2048
    /// Defensive clamp on the response text a page reports (the reporter already caps it ~16 KB).
    private static let maxResponseBodyChars = 20_000

    init(store: NetworkLogStore) {
        self.store = store
    }

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kindRaw = body["kind"] as? String,
              var url = body["url"] as? String, !url.isEmpty else { return }
        if url.count > Self.maxURLLength { url = String(url.prefix(Self.maxURLLength)) + "…" }

        let kind: NetworkLogEntry.Kind = (kindRaw == "xhr") ? .xhr : .fetch
        let method = (body["method"] as? String).map { String($0.prefix(16)) } ?? "GET"
        let status = (body["status"] as? Int) ?? 0
        let duration = body["duration"] as? Int
        let error = (body["error"] as? String).map { String($0.prefix(500)) }
        // The reporter already bounds the body; clamp again defensively against a hostile page.
        let responseBody = (body["responseBody"] as? String).map { String($0.prefix(Self.maxResponseBodyChars)) }

        let entry = NetworkLogEntry(kind: kind,
                                    method: method,
                                    url: url,
                                    statusCode: status,
                                    durationMs: duration,
                                    responseBody: responseBody,
                                    error: error)
        Task { await store.append(entry) }
    }
}
