//
//  WebExtensionCookieMapperTests.swift
//  BrownBearTests
//
//  Pure-logic coverage for the chrome.cookies value mapping: `HTTPCookie` → the chrome Cookie shape
//  and the inverse (chrome `setDetails` → `HTTPCookie`). No WebKit cookie jar needed — `HTTPCookie`
//  is a Foundation value type, so the mapper is fully exercisable in isolation. Table-driven where it
//  earns it, with malformed input (missing url) covered per the parser-testing rule in CLAUDE.md.
//

import XCTest
@testable import BrownBear

final class WebExtensionCookieMapperTests: XCTestCase {

    private func makeCookie(name: String = "sid", value: String = "abc", domain: String = "example.com",
                            path: String = "/", secure: Bool = false, httpOnly: Bool = false,
                            expires: Date? = nil, sameSite: HTTPCookieStringPolicy? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "YES" }
        if let expires { props[.expires] = expires }
        if let sameSite { props[.sameSitePolicy] = sameSite.rawValue }
        guard let cookie = HTTPCookie(properties: props) else {
            fatalError("test fixture cookie failed to construct")
        }
        return cookie
    }

    // MARK: - HTTPCookie → chrome Cookie

    func testHostOnlyCookieMapsToBareDomainAndHostOnlyTrue() {
        let mapped = WebExtensionCookieMapper.chromeCookie(from: makeCookie(domain: "example.com"))
        XCTAssertEqual(mapped["name"] as? String, "sid")
        XCTAssertEqual(mapped["value"] as? String, "abc")
        XCTAssertEqual(mapped["domain"] as? String, "example.com")
        XCTAssertEqual(mapped["hostOnly"] as? Bool, true)
        XCTAssertEqual(mapped["storeId"] as? String, "0")
    }

    func testDomainCookieKeepsLeadingDotAndIsNotHostOnly() {
        let mapped = WebExtensionCookieMapper.chromeCookie(from: makeCookie(domain: ".example.com"))
        XCTAssertEqual(mapped["domain"] as? String, ".example.com")
        XCTAssertEqual(mapped["hostOnly"] as? Bool, false)
    }

    func testSessionCookieOmitsExpirationAndReportsSession() {
        let mapped = WebExtensionCookieMapper.chromeCookie(from: makeCookie(expires: nil))
        XCTAssertEqual(mapped["session"] as? Bool, true)
        XCTAssertNil(mapped["expirationDate"])
    }

    func testPersistentCookieCarriesExpirationSeconds() throws {
        // Build the persistent cookie from a real Set-Cookie header: HTTPCookie(properties:[.expires:Date])
        // does not reliably populate `expiresDate` on the iOS runtime, whereas the header-parse path
        // (the one WebKit itself uses) does. "Wed, 18 May 2033 03:33:20 GMT" == 2_000_000_000 epoch sec.
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        let header = ["Set-Cookie": "sid=abc; Domain=example.com; Path=/; Expires=Wed, 18 May 2033 03:33:20 GMT"]
        let cookie = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: header, for: url).first)
        let mapped = WebExtensionCookieMapper.chromeCookie(from: cookie)
        XCTAssertEqual(mapped["session"] as? Bool, false)
        let expiry = try XCTUnwrap(mapped["expirationDate"] as? Double)
        XCTAssertEqual(expiry, 2_000_000_000, accuracy: 1.0)
    }

    func testSecureAndSameSiteMapThrough() {
        let mapped = WebExtensionCookieMapper.chromeCookie(
            from: makeCookie(secure: true, sameSite: .sameSiteStrict))
        XCTAssertEqual(mapped["secure"] as? Bool, true)
        XCTAssertEqual(mapped["sameSite"] as? String, "strict")
    }

    func testSameSiteStringTable() {
        XCTAssertEqual(WebExtensionCookieMapper.sameSiteString(nil), "unspecified")
        XCTAssertEqual(WebExtensionCookieMapper.sameSiteString(.sameSiteStrict), "strict")
        XCTAssertEqual(WebExtensionCookieMapper.sameSiteString(.sameSiteLax), "lax")
    }

    // MARK: - chrome setDetails → HTTPCookie

    func testSetDetailsRequiresURL() {
        XCTAssertNil(WebExtensionCookieMapper.cookie(fromSetDetails: ["name": "x", "value": "y"]))
    }

    func testSetDetailsRejectsURLWithNoHost() {
        XCTAssertNil(WebExtensionCookieMapper.cookie(fromSetDetails: ["url": "about:blank", "name": "x"]))
    }

    func testSetDetailsDerivesHostOnlyDomainFromURL() {
        let cookie = WebExtensionCookieMapper.cookie(fromSetDetails: [
            "url": "https://www.example.com/path", "name": "k", "value": "v"
        ])
        XCTAssertEqual(cookie?.name, "k")
        XCTAssertEqual(cookie?.value, "v")
        XCTAssertEqual(cookie?.domain, "www.example.com")   // host-only ⇒ no leading dot
        XCTAssertEqual(cookie?.path, "/")                   // default path
    }

    func testSetDetailsExplicitDomainBecomesDomainCookie() {
        let cookie = WebExtensionCookieMapper.cookie(fromSetDetails: [
            "url": "https://www.example.com/", "name": "k", "value": "v", "domain": "example.com"
        ])
        XCTAssertEqual(cookie?.domain, ".example.com")      // domain cookie ⇒ leading dot
    }

    func testSetDetailsExpirationProducesPersistentCookie() {
        let cookie = WebExtensionCookieMapper.cookie(fromSetDetails: [
            "url": "https://example.com/", "name": "k", "value": "v",
            "expirationDate": 2_000_000_000.0
        ])
        XCTAssertNotNil(cookie?.expiresDate)
        XCTAssertFalse(cookie?.isSessionOnly ?? true)
    }

    func testSetDetailsNoExpirationProducesSessionCookie() {
        let cookie = WebExtensionCookieMapper.cookie(fromSetDetails: [
            "url": "https://example.com/", "name": "k", "value": "v"
        ])
        XCTAssertTrue(cookie?.isSessionOnly ?? false)
    }

    func testSetDetailsSecureRoundTripsThroughChromeShape() throws {
        let cookie = try XCTUnwrap(WebExtensionCookieMapper.cookie(fromSetDetails: [
            "url": "https://example.com/", "name": "rt", "value": "1",
            "domain": "example.com", "secure": true
        ]))
        let mapped = WebExtensionCookieMapper.chromeCookie(from: cookie)
        XCTAssertEqual(mapped["name"] as? String, "rt")
        XCTAssertEqual(mapped["domain"] as? String, ".example.com")
        XCTAssertEqual(mapped["hostOnly"] as? Bool, false)
        XCTAssertEqual(mapped["secure"] as? Bool, true)
    }

    func testSameSitePolicyParsesNoRestriction() {
        XCTAssertEqual(WebExtensionCookieMapper.sameSitePolicy("strict"), .sameSiteStrict)
        XCTAssertEqual(WebExtensionCookieMapper.sameSitePolicy("lax"), .sameSiteLax)
        XCTAssertNil(WebExtensionCookieMapper.sameSitePolicy("unspecified"))
        XCTAssertEqual(WebExtensionCookieMapper.sameSitePolicy("no_restriction")?.rawValue, "None")
    }
}
