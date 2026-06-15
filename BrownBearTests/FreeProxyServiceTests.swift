//
//  FreeProxyServiceTests.swift
//  BrownBearTests
//
//  The free-proxy list parsers (ProxyScrape v4 + monosans) and the shaping helpers (validation, dedupe,
//  cap, country grouping, filter). Pure functions over fixture JSON — no network — matching the testable
//  shape of BBProxyTests. Fixtures mirror the real wire formats verified against the live endpoints.
//

import XCTest
@testable import BrownBear

final class FreeProxyServiceTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - ProxyScrape v4

    private let proxyScrapeJSON = """
    {"shown_records":5,"total_records":10,"proxies":[
     {"alive":true,"anonymity":"elite","ip":"91.107.168.255","port":83,"protocol":"http","ssl":true,
      "ip_data":{"country":"Germany","countryCode":"DE","city":"Frankfurt"}},
     {"alive":true,"ip":"27.75.149.73","port":1080,"protocol":"socks4",
      "ip_data":{"country":"Vietnam","countryCode":"VN"}},
     {"alive":false,"ip":"1.2.3.4","port":8080,"protocol":"http","ip_data":{"country":"X","countryCode":"US"}},
     {"alive":true,"ip":"5.6.7.8","port":0,"protocol":"http","ip_data":{"country":"France","countryCode":"FR"}},
     {"alive":true,"ip":"9.9.9.9","port":3128,"protocol":"https","ip_data":{"country":"Germany","countryCode":"DE"}}
    ]}
    """

    func testParseProxyScrapeMapsAndFilters() throws {
        let list = try FreeProxyService.parseProxyScrape(data(proxyScrapeJSON))
        XCTAssertEqual(list.count, 3, "alive:false and port:0 entries are dropped")
        let first = try XCTUnwrap(list.first)
        XCTAssertEqual(first.host, "91.107.168.255")
        XCTAssertEqual(first.port, 83)
        XCTAssertEqual(first.kind, .http)
        XCTAssertEqual(first.countryCode, "DE")
        XCTAssertEqual(first.countryName, "Germany")
        XCTAssertTrue(list.contains { $0.host == "27.75.149.73" && $0.kind == .socks5 }, "socks4 maps to socks5")
        XCTAssertFalse(list.contains { $0.host == "1.2.3.4" }, "dead proxy excluded")
        XCTAssertFalse(list.contains { $0.host == "5.6.7.8" }, "port 0 excluded")
    }

    // MARK: - monosans

    private let monosansJSON = """
    [
     {"protocol":"http","username":null,"password":null,"host":"185.200.188.234","port":10001,
      "geolocation":{"country":{"iso_code":"RU","names":{"en":"Russia"}},"city":{"names":{"en":"Moscow"}}}},
     {"protocol":"socks5","host":"82.97.247.37","port":1080,
      "geolocation":{"country":{"iso_code":"US","names":{"en":"United States"}}}},
     {"protocol":"http","host":"bad host","port":80,
      "geolocation":{"country":{"iso_code":"DE","names":{"en":"Germany"}}}}
    ]
    """

    func testParseMonosansMapsGeolocation() throws {
        let list = try FreeProxyService.parseMonosans(data(monosansJSON))
        XCTAssertEqual(list.count, 2, "the entry with an invalid host is rejected")
        let first = try XCTUnwrap(list.first)
        XCTAssertEqual(first.host, "185.200.188.234")
        XCTAssertEqual(first.countryCode, "RU")
        XCTAssertEqual(first.countryName, "Russia")
        XCTAssertTrue(list.contains { $0.host == "82.97.247.37" && $0.kind == .socks5 })
    }

    // MARK: - Validation, dedupe, cap

    func testGarbageThrows() {
        XCTAssertThrowsError(try FreeProxyService.parseProxyScrape(data("not json")))
        XCTAssertThrowsError(try FreeProxyService.parseMonosans(data("{}")))
    }

    func testInvalidHostOrPortRejected() {
        XCTAssertNil(FreeProxy(host: "", port: 8080, kind: .http, countryCode: nil, countryName: nil))
        XCTAssertNil(FreeProxy(host: "host", port: 0, kind: .http, countryCode: nil, countryName: nil))
        XCTAssertNil(FreeProxy(host: "host", port: 70_000, kind: .http, countryCode: nil, countryName: nil))
        XCTAssertNil(FreeProxy(host: "has space", port: 80, kind: .http, countryCode: nil, countryName: nil))
        XCTAssertNil(FreeProxy(host: "http://x.com", port: 80, kind: .http, countryCode: nil, countryName: nil))
        XCTAssertNotNil(FreeProxy(host: "1.2.3.4", port: 80, kind: .http, countryCode: "us", countryName: "USA"))
    }

    func testPostProcessDedupesAndCaps() {
        var many: [FreeProxy] = []
        for index in 0..<500 {
            if let proxy = FreeProxy(host: "10.0.\(index / 256).\(index % 256)", port: 8000 + (index % 1000),
                                     kind: .http, countryCode: "US", countryName: "USA") {
                many.append(proxy)
            }
        }
        many.append(contentsOf: many.prefix(40))   // inject duplicates
        let processed = FreeProxyService.postProcess(many)
        XCTAssertEqual(processed.count, 300, "capped at maxEntries")
        XCTAssertEqual(Set(processed.map(\.hostPort)).count, processed.count, "no duplicate host:port survives")
    }

    // MARK: - Country grouping + filter

    func testCountryGroupingSortedByCountThenCode() throws {
        let list = try FreeProxyService.parseProxyScrape(data(proxyScrapeJSON))
        let countries = FreeProxyService.countries(in: list)
        XCTAssertEqual(countries.first?.code, "DE", "the country with the most proxies leads")
        XCTAssertEqual(countries.first?.count, 2)
        XCTAssertEqual(countries.first?.flag, "🇩🇪")
        XCTAssertTrue(countries.contains { $0.code == "VN" && $0.count == 1 })
    }

    func testCountryNameUpgradesRegardlessOfArrivalOrder() {
        // First DE entry carries no name; a later DE entry does — the bucket must show "Germany", not "DE".
        let list = [
            FreeProxy(host: "1.1.1.1", port: 80, kind: .http, countryCode: "DE", countryName: nil),
            FreeProxy(host: "2.2.2.2", port: 80, kind: .http, countryCode: "DE", countryName: "Germany")
        ].compactMap { $0 }
        let countries = FreeProxyService.countries(in: list)
        XCTAssertEqual(countries.first?.code, "DE")
        XCTAssertEqual(countries.first?.name, "Germany", "a later real name isn't locked out by an earlier nil")
        XCTAssertEqual(countries.first?.count, 2)
    }

    func testUnknownCountryBucket() {
        let noCountry = [FreeProxy(host: "7.7.7.7", port: 9090, kind: .http,
                                   countryCode: nil, countryName: nil)].compactMap { $0 }
        let countries = FreeProxyService.countries(in: noCountry)
        XCTAssertEqual(countries.first?.code, FreeProxy.unknownCode)
        XCTAssertEqual(countries.first?.name, "Unknown")
        XCTAssertEqual(countries.first?.flag, "🌐")
    }

    func testFilterByCountry() throws {
        let list = try FreeProxyService.parseProxyScrape(data(proxyScrapeJSON))
        XCTAssertEqual(FreeProxyService.filter(list, countryCode: "DE").count, 2)
        XCTAssertEqual(FreeProxyService.filter(list, countryCode: nil).count, 3, "nil means All")
        XCTAssertEqual(FreeProxyService.filter(list, countryCode: "").count, 3, "empty means All")
    }

    // MARK: - asBBProxy

    func testAsBBProxyHasNoCredentials() throws {
        let list = try FreeProxyService.parseProxyScrape(data(proxyScrapeJSON))
        let proxy = try XCTUnwrap(list.first)
        let stored = proxy.asBBProxy(label: "Free · DE")
        XCTAssertEqual(stored.host, "91.107.168.255")
        XCTAssertEqual(stored.port, 83)
        XCTAssertEqual(stored.kind, .http)
        XCTAssertEqual(stored.label, "Free · DE")
        XCTAssertFalse(stored.hasCredentials)
    }
}
