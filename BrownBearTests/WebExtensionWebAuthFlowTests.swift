//
//  WebExtensionWebAuthFlowTests.swift
//  BrownBearTests
//
//  chrome.identity.launchWebAuthFlow request parsing + the no-UI dispatch branches. The auth URL is
//  untrusted extension input, so parse() must accept only absolute http(s) URLs and derive the
//  chromiumapp.org callback host from the extension id. The interactive:false and bad-URL paths return
//  before any system UI is presented, so they're verifiable headlessly; the actual auth presentation is
//  device-gated (ASWebAuthenticationSession).
//

import XCTest
@testable import BrownBear

final class WebExtensionWebAuthFlowTests: XCTestCase {

    // MARK: - WebAuthFlowRequest.parse (pure)

    func testParsesValidHTTPSRequestAndDerivesCallbackHost() {
        let request = WebAuthFlowRequest.parse(
            args: ["url": "https://accounts.example.com/o/oauth2/auth?client_id=x", "interactive": true],
            extensionID: "abcdef")
        XCTAssertEqual(request?.authURL.absoluteString, "https://accounts.example.com/o/oauth2/auth?client_id=x")
        XCTAssertEqual(request?.callbackHost, "abcdef.chromiumapp.org", "callback host derived from the extension id")
        XCTAssertEqual(request?.interactive, true)
    }

    func testInteractiveDefaultsToFalseWhenOmitted() {
        let request = WebAuthFlowRequest.parse(args: ["url": "https://host.example/auth"], extensionID: "ext")
        XCTAssertEqual(request?.interactive, false)
    }

    func testRejectsInvalidOrUnsafeInput() {
        XCTAssertNil(WebAuthFlowRequest.parse(args: [:], extensionID: "ext"), "missing url")
        XCTAssertNil(WebAuthFlowRequest.parse(args: ["url": ""], extensionID: "ext"), "empty url")
        XCTAssertNil(WebAuthFlowRequest.parse(args: ["url": 42], extensionID: "ext"), "non-string url")
        XCTAssertNil(WebAuthFlowRequest.parse(args: ["url": "ftp://host/x"], extensionID: "ext"), "non-http scheme")
        XCTAssertNil(WebAuthFlowRequest.parse(args: ["url": "javascript:alert(1)"], extensionID: "ext"), "js scheme")
        XCTAssertNil(WebAuthFlowRequest.parse(args: ["url": "https:///nohost"], extensionID: "ext"), "no host")
        XCTAssertNil(WebAuthFlowRequest.parse(args: ["url": "https://h/x"], extensionID: ""), "empty extension id")
    }

    func testAcceptsHTTPAsWellAsHTTPS() {
        XCTAssertNotNil(WebAuthFlowRequest.parse(args: ["url": "http://host.example/auth"], extensionID: "ext"))
    }

    // MARK: - dispatch (the no-UI branches; the auth presentation itself is device-gated)

    @MainActor
    func testDispatchInteractiveFalseReportsInteractionRequired() async {
        let result = await WebExtensionWebAuthFlow.dispatch(
            method: "launchWebAuthFlow",
            args: ["url": "https://accounts.example.com/auth", "interactive": false],
            extensionID: "ext")
        XCTAssertEqual(result["error"] as? String, WebAuthFlowError.interactionRequired.message)
        XCTAssertNil(result["responseUrl"])
    }

    @MainActor
    func testDispatchBadURLReportsError() async {
        let result = await WebExtensionWebAuthFlow.dispatch(
            method: "launchWebAuthFlow", args: ["url": "not a url at all"], extensionID: "ext")
        XCTAssertEqual(result["error"] as? String, WebAuthFlowError.badURL.message)
    }

    @MainActor
    func testDispatchUnsupportedMethodReportsError() async {
        let result = await WebExtensionWebAuthFlow.dispatch(method: "getAuthToken", args: [:], extensionID: "ext")
        XCTAssertNotNil(result["error"])
    }
}
