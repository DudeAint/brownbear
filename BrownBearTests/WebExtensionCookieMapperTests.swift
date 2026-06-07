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
        // A near-future expiry (1h), NOT a far-future absolute — WebKit/iOS clamps a cookie's expiry to
        // a platform cap (~400 days), so a year-2033 date would come back clamped and break an exact
        // assertion. The mapper's job is to pass the cookie's OWN expiresDate straight through, so we
        // assert it equals exactly that (and that the cookie is reported persistent, not session).
        let cookie = makeCookie(expires: Date().addingTimeInterval(3600))
        let cookieExpiry = try XCTUnwrap(cookie.expiresDate?.timeIntervalSince1970)
        let mapped = WebExtensionCookieMapper.chromeCookie(from: cookie)
        XCTAssertEqual(mapped["session"] as? Bool, false)
        let expiry = try XCTUnwrap(mapped["expirationDate"] as? Double)
        XCTAssertEqual(expiry, cookieExpiry, accuracy: 0.001)
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
