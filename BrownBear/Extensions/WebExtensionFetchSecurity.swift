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
