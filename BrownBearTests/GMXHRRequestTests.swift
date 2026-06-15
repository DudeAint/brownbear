//
//  GMXHRRequestTests.swift
//  BrownBearTests
//
//  Pins GM_xmlhttpRequest request decoding (GMNetworkService.GMXHRRequest) for the two Tampermonkey/
//  Violentmonkey parity features added for page-world userscripts:
//    • a BINARY request body crosses the bridge base64-encoded (`dataIsBase64`) and decodes back to the
//      exact bytes — never the lossy UTF-8 of the base64 text;
//    • `overrideMimeType` is parsed, and `overrideForcesBinaryText` correctly decides when the response
//      must be delivered as a byte-preserving string (the `charset=x-user-defined` trick / non-text MIME).
//

import XCTest
@testable import BrownBear

final class GMXHRRequestTests: XCTestCase {

    private func req(_ overrides: [String: Any]) -> GMXHRRequest? {
        var payload: [String: Any] = ["url": "https://example.com/u", "method": "POST"]
        for (k, v) in overrides { payload[k] = v }
        return GMXHRRequest(payload: payload)
    }

    func testBase64BodyDecodesToExactBytes() {
        let bytes: [UInt8] = [1, 2, 3, 0, 255, 128]
        let b64 = Data(bytes).base64EncodedString()
        let r = req(["data": b64, "dataIsBase64": true])
        XCTAssertEqual(r?.body.map(Array.init), bytes,
                       "a flagged-base64 body must decode to the original raw bytes")
    }

    func testNonFlaggedStringBodyStaysUTF8() {
        let r = req(["data": "hello=1"])
        XCTAssertEqual(r?.body, "hello=1".data(using: .utf8),
                       "a plain string body is sent as UTF-8, not base64-decoded")
    }

    func testMalformedBase64BodyFailsClosedToNil() {
        // Not a body smuggling the literal base64 text — a bad payload yields no body.
        let r = req(["data": "!!!not base64!!!", "dataIsBase64": true])
        XCTAssertNil(r?.body, "an undecodable base64 body must fail closed to no body")
    }

    func testOverrideMimeTypeParsedAndTrimmed() {
        XCTAssertEqual(req(["overrideMimeType": "  text/plain; charset=x-user-defined  "])?.overrideMimeType,
                       "text/plain; charset=x-user-defined")
        XCTAssertNil(req(["overrideMimeType": "   "])?.overrideMimeType, "blank override is nil")
        XCTAssertNil(req([:])?.overrideMimeType, "absent override is nil")
    }

    func testOverrideForcesBinaryTextDecision() {
        // x-user-defined → binary string, regardless of the text/ major type.
        XCTAssertTrue(req(["overrideMimeType": "text/plain; charset=x-user-defined"])?.overrideForcesBinaryText ?? false)
        // Non-text MIME → binary.
        XCTAssertTrue(req(["overrideMimeType": "application/octet-stream"])?.overrideForcesBinaryText ?? false)
        XCTAssertTrue(req(["overrideMimeType": "image/png"])?.overrideForcesBinaryText ?? false)
        // Plain text / structured-text MIMEs decode as UTF-8 text, not bytes.
        XCTAssertFalse(req(["overrideMimeType": "text/plain"])?.overrideForcesBinaryText ?? true)
        XCTAssertFalse(req(["overrideMimeType": "application/json"])?.overrideForcesBinaryText ?? true)
        XCTAssertFalse(req(["overrideMimeType": "application/xml"])?.overrideForcesBinaryText ?? true)
        // No override at all → not forced.
        XCTAssertFalse(req([:])?.overrideForcesBinaryText ?? true)
    }

    func testArraybufferResponseTypeStillWantsBinaryRegardlessOfOverride() {
        // wantsBinary (arraybuffer/blob) drives the `response` path; overrideForcesBinaryText is only for
        // the text path, so it must be false when wantsBinary is true (no double handling).
        let r = req(["responseType": "arraybuffer", "overrideMimeType": "application/octet-stream"])
        XCTAssertTrue(r?.wantsBinary ?? false)
        XCTAssertFalse(r?.overrideForcesBinaryText ?? true,
                       "an arraybuffer response uses the response path, not the binary-text path")
    }
}
