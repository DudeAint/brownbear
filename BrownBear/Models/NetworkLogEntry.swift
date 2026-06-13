//
//  NetworkLogEntry.swift
//  BrownBear
//
//  One captured network request for the Logs → Network inspector. Covers the request channels BrownBear
//  can see: a userscript's GM_xmlhttpRequest (proxied through the native URLSession), and — once the page
//  reporter is wired — a page/userscript `fetch` or `XMLHttpRequest`. Held in memory only (never written to
//  disk): a network log is voluminous and may carry auth headers, so it lives for the session and is gone
//  on relaunch, like a browser's DevTools network panel.
//

import Foundation

/// A single network request shown in the Network tab. Value type; equatable so SwiftUI diffs cheaply.
struct NetworkLogEntry: Identifiable, Equatable, Sendable {

    /// How the request was issued — the badge shown in the collapsed row.
    enum Kind: String, Codable, Sendable {
        case gmXHR          // GM_xmlhttpRequest (native URLSession proxy)
        case fetch          // window.fetch from a page or userscript
        case xhr            // XMLHttpRequest from a page or userscript
        case hostFetch      // an extension page's host-permitted fetch

        /// Label for the row badge.
        var displayName: String {
            switch self {
            case .gmXHR: return "GM_xmlhttpRequest"
            case .fetch: return "fetch"
            case .xhr: return "XHR"
            case .hostFetch: return "fetch"
            }
        }
    }

    let id: UUID
    let createdAt: Date
    let kind: Kind
    /// Uppercased HTTP method (GET/POST/…).
    let method: String
    /// The full request URL as a string (kept verbatim for the detail view).
    let url: String
    /// HTTP status code; 0 means the request failed before a response (network error / blocked / aborted).
    let statusCode: Int
    /// The userscript that issued it (GM_xmlhttpRequest), when known.
    let scriptName: String?
    /// Wall-clock duration in milliseconds, when measured.
    let durationMs: Int?
    let requestHeaders: [String: String]
    let responseHeaders: [String: String]
    /// The request body as text, if it was a string body (truncated by the producer).
    let requestBody: String?
    /// Response payload size in bytes, when known.
    let responseBytes: Int?
    /// A failure reason when `statusCode == 0` (or an explicit transport error).
    let error: String?

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         kind: Kind,
         method: String,
         url: String,
         statusCode: Int,
         scriptName: String? = nil,
         durationMs: Int? = nil,
         requestHeaders: [String: String] = [:],
         responseHeaders: [String: String] = [:],
         requestBody: String? = nil,
         responseBytes: Int? = nil,
         error: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.method = method.uppercased()
        self.url = url
        self.statusCode = statusCode
        self.scriptName = scriptName
        self.durationMs = durationMs
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBytes = responseBytes
        self.error = error
    }

    /// The host shown in the collapsed row; falls back to the raw URL for opaque/relative URLs.
    var host: String {
        guard let host = URL(string: url)?.host, !host.isEmpty else {
            // A relative or non-standard URL — show its leading path-ish chunk rather than nothing.
            return url
        }
        return host
    }

    /// The path+query shown under the host in the row, for at-a-glance disambiguation.
    var pathAndQuery: String {
        guard let components = URLComponents(string: url) else { return "" }
        var out = components.path
        if let query = components.query, !query.isEmpty { out += "?" + query }
        return out
    }

    /// True when the request did not complete with a normal HTTP response.
    var isFailure: Bool { statusCode == 0 || statusCode >= 400 }
}
