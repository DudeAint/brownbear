//
//  CookieChangeObserverTests.swift
//  BrownBearTests
//
//  chrome.cookies.onChanged must fire for ANY observable attribute change (not just value): Chrome
//  reports a secure/httpOnly/sameSite/expiry flip as an overwrite. attributesDiffer is the pure
//  comparison the observer's diff uses — tested directly (the live WKHTTPCookieStore observer needs a
//  real store + run loop).
//

import XCTest
@testable import BrownBear

@MainActor
final class CookieChangeObserverTests: XCTestCase {

    private func makeCookie(value: String = "v", secure: Bool = false, expires: Date? = nil,
                            sameSite: HTTPCookieStringPolicy? = nil) throws -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: "session", .domain: "example.com", .path: "/", .value: value]
        if secure { props[.secure] = "TRUE" }
        if let expires { props[.expires] = expires }
        if let sameSite { props[.sameSitePolicy] = sameSite.rawValue }
        return try XCTUnwrap(HTTPCookie(properties: props))
    }

    func testIdenticalCookiesDoNotDiffer() throws {
        XCTAssertFalse(WebExtensionCookieObserver.attributesDiffer(try makeCookie(), try makeCookie()))
    }

    func testValueChangeDiffers() throws {
        XCTAssertTrue(WebExtensionCookieObserver.attributesDiffer(
            try makeCookie(value: "1"), try makeCookie(value: "2")))
    }

    func testSecureFlipDiffers() throws {
        // The reported gap: a value-equal cookie whose `secure` flips must still fire onChanged.
        XCTAssertTrue(WebExtensionCookieObserver.attributesDiffer(
            try makeCookie(secure: false), try makeCookie(secure: true)))
    }

    func testExpiryChangeDiffers() throws {
        XCTAssertTrue(WebExtensionCookieObserver.attributesDiffer(
            try makeCookie(expires: Date(timeIntervalSince1970: 1000)),
            try makeCookie(expires: Date(timeIntervalSince1970: 2000))))
    }

    func testSameSiteChangeDiffers() throws {
        XCTAssertTrue(WebExtensionCookieObserver.attributesDiffer(
            try makeCookie(sameSite: .sameSiteLax), try makeCookie(sameSite: .sameSiteStrict)))
    }
}
