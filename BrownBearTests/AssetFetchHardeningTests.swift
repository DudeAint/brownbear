//
//  AssetFetchHardeningTests.swift
//  BrownBearTests
//
//  The @require/@resource native fetch (ScriptMessageRouter.fetchAndCacheAsset) must fail closed on
//  non-http(s) schemes (no local file:// read at install/runtime) and must NEVER let an error/redirect
//  response overwrite — or be served in place of — a last-good cached asset. These guard two HIGH
//  findings from the adversarial audit: a file:// local-file-read at install-time prefetch, and a
//  transient 4xx/5xx/blocked-redirect permanently poisoning a working @require.
//

import XCTest
@testable import BrownBear

/// Serves canned (status, body) responses per URL so the HTTP-status handling can be driven without a
/// network. Used via a custom URLSession whose configuration lists it in `protocolClasses`.
final class StubURLProtocol: URLProtocol {
    static var responses: [String: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.flatMap { responses[$0.absoluteString] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = StubURLProtocol.responses[url.absoluteString],
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/javascript"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AssetFetchHardeningTests: XCTestCase {

    private var cacheDir: URL!
    private var cache: GMAssetCache!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aft-\(UUID().uuidString)", isDirectory: true)
        cache = GMAssetCache(directory: cacheDir)
        StubURLProtocol.responses = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.responses = [:]
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    func testNonHttpSchemeIsRejectedWithoutFetching() async {
        do {
            _ = try await ScriptMessageRouter.fetchAndCacheAsset(
                URL(string: "file:///etc/passwd")!, connects: [], cache: cache, session: session)
            XCTFail("a file:// @require/@resource must be rejected, never fetched (local file read)")
        } catch {
            // expected — fail closed
        }
    }

    func testErrorStatusDoesNotOverwriteGoodCache() async throws {
        let url = URL(string: "https://cdn.test/lib.js")!
        let good = GMAssetCache.Entry(data: Data("/*jquery*/".utf8), etag: nil, lastModified: nil,
                                      mimeType: "application/javascript")
        await cache.store(good, for: url)                                   // a prior 200 cached it
        StubURLProtocol.responses[url.absoluteString] = (404, Data("<html>not found</html>".utf8))

        let (data, _) = try await ScriptMessageRouter.fetchAndCacheAsset(
            url, connects: [], cache: cache, session: session)
        XCTAssertEqual(data, good.data, "a 404 serves the last-good cached body, not the error page")
        let stored = await cache.entry(for: url)
        XCTAssertEqual(stored?.data, good.data, "a 404 must NOT overwrite the good cache entry")
    }

    func testErrorStatusWithNoCacheThrows() async {
        let url = URL(string: "https://cdn.test/missing.js")!
        StubURLProtocol.responses[url.absoluteString] = (503, Data("oops".utf8))
        do {
            _ = try await ScriptMessageRouter.fetchAndCacheAsset(url, connects: [], cache: cache, session: session)
            XCTFail("a 5xx with no cached copy must throw, never cache the error body")
        } catch {
            // expected
        }
    }

    func testSuccessCachesAndReturnsTheBody() async throws {
        let url = URL(string: "https://cdn.test/ok.js")!
        let body = Data("console.log(1)".utf8)
        StubURLProtocol.responses[url.absoluteString] = (200, body)
        let (data, _) = try await ScriptMessageRouter.fetchAndCacheAsset(
            url, connects: [], cache: cache, session: session)
        XCTAssertEqual(data, body)
        let stored = await cache.entry(for: url)
        XCTAssertEqual(stored?.data, body, "a 200 body is cached")
    }
}
