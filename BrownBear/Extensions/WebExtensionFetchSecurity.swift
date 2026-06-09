//
//  WebExtensionFetchSecurity.swift
//  BrownBear
//
//  Hardening shared by the two extension fetch surfaces — the service worker's `__bb_fetch`
//  (WebExtensionBackgroundContext+Fetch) and the extension-page `hostFetch` proxy
//  (WebExtensionMessageRouter+Permissions). Both reach arbitrary hosts on behalf of UNTRUSTED extension
//  JavaScript, so both must (CLAUDE.md §5):
//
//   • Keep the host_permissions gate honest ACROSS REDIRECTS. The gate checks the initial URL, but
//     URLSession follows 3xx by default — a permitted host could 302 the request onto an undeclared or
//     internal/loopback host (SSRF) and hand the extension that body. `RedirectGuard` re-checks every
//     redirect target against the same host_permissions and refuses to follow one that isn't permitted.
//   • Reject request headers that smuggle CR/LF/NUL (header injection / request smuggling), and names
//     that aren't valid HTTP tokens.
//

import Foundation

enum WebExtensionFetchSecurity {

    /// A URLSession delegate that re-applies the host_permissions gate to every HTTP redirect: a redirect
    /// to a host the extension didn't declare is NOT followed (the redirect response is returned as-is, so
    /// the off-host request is never made). Used with a per-request session that is invalidated after.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        private let hostPatterns: [String]
        init(hostPatterns: [String]) { self.hostPatterns = hostPatterns }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // Build the matcher per redirect (redirects are rare); same gate as chrome.cookies/host fetch.
            let matcher = URLMatcher(matches: hostPatterns, includes: [], excludes: [], excludeMatches: [])
            if let url = request.url?.absoluteString, matcher.matches(url) {
                completionHandler(request)   // permitted → follow
            } else {
                completionHandler(nil)        // undeclared/internal host → stop following (SSRF guard)
            }
        }
    }

    /// A URLSession that enforces the host_permissions gate on redirects. Uses the `.default`
    /// configuration so it shares the cookie store (a privileged extension fetch carries credentials for
    /// permitted hosts, like Chrome). Invalidate it (`finishTasksAndInvalidate`) once the request settles.
    static func redirectGuardedSession(hostPatterns: [String]) -> URLSession {
        URLSession(configuration: .default, delegate: RedirectGuard(hostPatterns: hostPatterns), delegateQueue: nil)
    }

    /// Redirect guard for chrome.downloads. Unlike the host_permissions-allowlisted fetch guard, downloads
    /// may target any PUBLIC http(s) host (Chrome does), so this guard fails closed on the SSRF vectors:
    /// a redirect to a non-http(s) scheme, or to a loopback/private/link-local host. It also strips the
    /// `Authorization`/`Cookie` request headers on a CROSS-ORIGIN redirect so worker-supplied credentials
    /// can't be forwarded to the redirect target.
    final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", !isBlockedHost(url.host) else {
                completionHandler(nil)   // non-http(s) or internal target → stop following (SSRF guard)
                return
            }
            // Strip credentials when the redirect crosses origin (scheme+host+port).
            var forwarded = request
            if !sameOrigin(task.originalRequest?.url, url) {
                forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
                forwarded.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            completionHandler(forwarded)
        }

        private func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
            guard let a, let b else { return false }
            return a.scheme?.lowercased() == b.scheme?.lowercased()
                && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
        }
    }

    /// A per-download URLSession that fails closed on SSRF redirect targets. Invalidate after the task
    /// settles (`finishTasksAndInvalidate`).
    static func downloadGuardedSession() -> URLSession {
        URLSession(configuration: .default, delegate: DownloadRedirectGuard(), delegateQueue: nil)
    }

    /// Whether `host` is a loopback / private / link-local / `.local` target an extension download must
    /// not reach (SSRF). String-based (covers literal IPs + localhost/.local); DNS-rebinding to an
    /// internal IP via a public hostname is out of scope here, as in the fetch guard.
    static func isBlockedHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }  // IPv6 literal
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        // IPv6 literal (contains a colon, so it can't be confused with a hostname like "fcdn.com"):
        // loopback ::1, unique-local fc00::/7, link-local fe80::/10.
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8")
                || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        // IPv4 literal in private/loopback/link-local ranges.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let octets = try? parts.map({ (s) -> Int in
            guard let n = Int(s), (0...255).contains(n) else { throw NSError(domain: "", code: 0) }
            return n
        }) {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            default: return false
            }
        }
        return false
    }

    /// Apply caller-supplied request headers, dropping any whose name isn't a valid HTTP token or whose
    /// value contains CR/LF/NUL — closing the header-injection / request-smuggling hole (URLRequest's
    /// setValue does NOT reject CRLF).
    static func apply(headers: [String: Any], to request: inout URLRequest) {
        for (name, rawValue) in headers {
            let value = String(describing: rawValue)
            guard isValidHeaderName(name),
                  value.rangeOfCharacter(from: Self.forbiddenHeaderValueChars) == nil else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static let forbiddenHeaderValueChars = CharacterSet(charactersIn: "\r\n\0")
    /// RFC 7230 header-name token characters.
    private static let headerNameTokenChars = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private static func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { Self.headerNameTokenChars.contains($0) }
    }
}
