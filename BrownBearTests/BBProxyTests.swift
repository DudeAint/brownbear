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

    // MARK: - Paste-any-format support

    func testHostPortUserPassSellerFormat() {
        // The ubiquitous "IP:PORT:USER:PASS" a proxy seller hands you.
        let p = BBProxy.parse("1.2.3.4:1080:alice:secret")
        XCTAssertEqual(p?.host, "1.2.3.4")
        XCTAssertEqual(p?.port, 1080)
        XCTAssertEqual(p?.username, "alice")
        XCTAssertEqual(p?.password, "secret")
    }

    func testUserPassHostPortInverted() {
        // The inverted "USER:PASS:HOST:PORT" — disambiguated because the LAST field is the numeric port.
        let p = BBProxy.parse("alice:secret:1.2.3.4:1080")
        XCTAssertEqual(p?.host, "1.2.3.4")
        XCTAssertEqual(p?.port, 1080)
        XCTAssertEqual(p?.username, "alice")
        XCTAssertEqual(p?.password, "secret")
    }

    func testHostPortAtUserPassInverted() {
        // Some providers print "host:port@user:pass" — the side ending in a port is the host side.
        let p = BBProxy.parse("1.2.3.4:1080@alice:secret")
        XCTAssertEqual(p?.host, "1.2.3.4")
        XCTAssertEqual(p?.port, 1080)
        XCTAssertEqual(p?.username, "alice")
        XCTAssertEqual(p?.password, "secret")
    }

    func testHostPortUserNoPassword() {
        let p = BBProxy.parse("1.2.3.4:1080:alice")
        XCTAssertEqual(p?.host, "1.2.3.4")
        XCTAssertEqual(p?.port, 1080)
        XCTAssertEqual(p?.username, "alice")
        XCTAssertEqual(p?.password, "")
    }

    func testWhitespaceAndCommaDelimited() {
        let space = BBProxy.parse("1.2.3.4 1080 alice secret")
        XCTAssertEqual(space?.host, "1.2.3.4")
        XCTAssertEqual(space?.port, 1080)
        XCTAssertEqual(space?.username, "alice")
        XCTAssertEqual(space?.password, "secret")
        let comma = BBProxy.parse("host,1080,user,pass")
        XCTAssertEqual(comma?.hostPort, "host:1080")
        XCTAssertEqual(comma?.password, "pass")
    }

    func testNumericPasswordKeepsStandardOrder() {
        // A numeric password must not be mistaken for the host side: creds stay on the left of '@'.
        let p = BBProxy.parse("admin:8080@1.2.3.4:3128")
        XCTAssertEqual(p?.username, "admin")
        XCTAssertEqual(p?.password, "8080")
        XCTAssertEqual(p?.host, "1.2.3.4")
        XCTAssertEqual(p?.port, 3128)
    }

    func testIPv6WithTrailingCredentials() {
        let p = BBProxy.parse("[2001:db8::1]:9050:user:pw")
        XCTAssertEqual(p?.host, "2001:db8::1")
        XCTAssertEqual(p?.port, 9050)
        XCTAssertEqual(p?.username, "user")
        XCTAssertEqual(p?.password, "pw")
    }

    func testQuotedAndPaddedInput() {
        let p = BBProxy.parse("  \"5.6.7.8:3128\"  ")
        XCTAssertEqual(p?.host, "5.6.7.8")
        XCTAssertEqual(p?.port, 3128)
    }
}
