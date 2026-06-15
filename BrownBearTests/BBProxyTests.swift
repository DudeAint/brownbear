//
//  BBProxyTests.swift
//  BrownBearTests
//
//  BBProxy.parse — the proxy-string parser behind the "paste a proxy" field. Covers full URLs, bare
//  host:port, embedded credentials (incl. a password containing ':'), IPv6 literals, scheme→kind mapping,
//  and rejection of malformed/out-of-range inputs.
//

import XCTest
@testable import BrownBear

final class BBProxyTests: XCTestCase {

    func testFullURLWithCredentials() {
        let p = BBProxy.parse("socks5://alice:s3cret@198.51.100.7:1080")
        XCTAssertEqual(p?.kind, .socks5)
        XCTAssertEqual(p?.host, "198.51.100.7")
        XCTAssertEqual(p?.port, 1080)
        XCTAssertEqual(p?.username, "alice")
        XCTAssertEqual(p?.password, "s3cret")
        XCTAssertTrue(p?.hasCredentials == true)
    }

    func testSchemeMapsToKind() {
        XCTAssertEqual(BBProxy.parse("http://host:3128")?.kind, .http)
        XCTAssertEqual(BBProxy.parse("https://host:3128")?.kind, .https)
        XCTAssertEqual(BBProxy.parse("socks5://host:1080")?.kind, .socks5)
        XCTAssertEqual(BBProxy.parse("socks://host:1080")?.kind, .socks5, "socks is treated as socks5")
    }

    func testBareHostPortUsesFallbackKind() {
        let p = BBProxy.parse("proxy.example.com:8080", fallbackKind: .http)
        XCTAssertEqual(p?.kind, .http)
        XCTAssertEqual(p?.host, "proxy.example.com")
        XCTAssertEqual(p?.port, 8080)
        XCTAssertFalse(p?.hasCredentials == true)
    }

    func testCredentialsWithoutScheme() {
        let p = BBProxy.parse("user:pass@10.0.0.1:8888")
        XCTAssertEqual(p?.host, "10.0.0.1")
        XCTAssertEqual(p?.port, 8888)
        XCTAssertEqual(p?.username, "user")
        XCTAssertEqual(p?.password, "pass")
    }

    func testPasswordContainingColon() {
        // The split is on the FIRST ':' of the credentials, so a ':'-bearing password survives.
        let p = BBProxy.parse("http://bob:p:a:ss@host:80")
        XCTAssertEqual(p?.username, "bob")
        XCTAssertEqual(p?.password, "p:a:ss")
        XCTAssertEqual(p?.host, "host")
        XCTAssertEqual(p?.port, 80)
    }

    func testIPv6Literal() {
        let p = BBProxy.parse("socks5://[2001:db8::1]:9050")
        XCTAssertEqual(p?.host, "2001:db8::1")
        XCTAssertEqual(p?.port, 9050)
    }

    func testRejectsMalformedOrOutOfRange() {
        XCTAssertNil(BBProxy.parse(""), "empty")
        XCTAssertNil(BBProxy.parse("nohostport"), "no port")
        XCTAssertNil(BBProxy.parse("host:0"), "port 0 is invalid")
        XCTAssertNil(BBProxy.parse("host:70000"), "port out of range")
        XCTAssertNil(BBProxy.parse("host:notaport"), "non-numeric port")
    }

    func testURLStringRoundTrips() {
        let p = BBProxy.parse("socks5://u:p@1.2.3.4:1080")
        XCTAssertEqual(p?.urlString, "socks5://u:p@1.2.3.4:1080")
        let noCreds = BBProxy.parse("http://1.2.3.4:3128")
        XCTAssertEqual(noCreds?.urlString, "http://1.2.3.4:3128")
    }

    func testIsCompleteGate() {
        XCTAssertTrue(BBProxy(host: "h", port: 8080).isComplete)
        XCTAssertFalse(BBProxy(host: "", port: 8080).isComplete)
        XCTAssertFalse(BBProxy(host: "h", port: 0).isComplete)
    }
}
