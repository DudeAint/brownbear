//
//  WebExtensionCryptoRSATests.swift
//  BrownBearTests
//
//  crypto.subtle RSA for the headless worker (WebExtensionBackgroundContext.rsa): generate → sign/verify
//  (PKCS1v15 + PSS), encrypt/decrypt (OAEP), and a JWK export→import round-trip that exercises the
//  PKCS#1↔JWK DER codec — a key that survives JWK and still produces verifiable signatures proves the
//  INTEGER/SEQUENCE encoding is correct. Pure Security-framework calls, no runtime dependency.
//

import XCTest
@testable import BrownBear

final class WebExtensionCryptoRSATests: XCTestCase {

    private func call(_ op: String, _ params: [String: Any]) -> [String: Any] {
        let json = WebExtensionBackgroundContext.rsa(op: op, params: params)
        return ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    }

    func testGenerateSignVerifyPKCS1v15() {
        let gen = call("rsaGenerate", ["modulusLength": 2048])
        let priv = gen["privatePkcs1"] as? String ?? "", pub = gen["publicPkcs1"] as? String ?? ""
        XCTAssertFalse(priv.isEmpty, "generated a private key: \(gen)")
        XCTAssertFalse(pub.isEmpty, "generated a public key")

        let data = Data("hello rsa".utf8).base64EncodedString()
        let sig = call("rsaSign", ["privatePkcs1": priv, "data": data, "hash": "SHA-256",
                                   "scheme": "RSASSA-PKCS1-v1_5"])["data"] as? String ?? ""
        XCTAssertFalse(sig.isEmpty, "produced a PKCS1v15 signature")
        XCTAssertEqual(call("rsaVerify", ["publicPkcs1": pub, "data": data, "signature": sig,
                                          "hash": "SHA-256", "scheme": "RSASSA-PKCS1-v1_5"])["valid"] as? Bool, true,
                       "the signature verifies")
        // A signature over DIFFERENT data must not verify.
        XCTAssertEqual(call("rsaVerify", ["publicPkcs1": pub, "data": Data("tampered".utf8).base64EncodedString(),
                                          "signature": sig, "hash": "SHA-256",
                                          "scheme": "RSASSA-PKCS1-v1_5"])["valid"] as? Bool, false,
                       "a signature over different data fails")
    }

    func testPSSSignVerifyAndOAEPEncryptDecrypt() {
        let gen = call("rsaGenerate", ["modulusLength": 2048])
        let priv = gen["privatePkcs1"] as? String ?? "", pub = gen["publicPkcs1"] as? String ?? ""

        let data = Data("pss payload".utf8).base64EncodedString()
        let pss = call("rsaSign", ["privatePkcs1": priv, "data": data, "hash": "SHA-256",
                                   "scheme": "RSA-PSS"])["data"] as? String ?? ""
        XCTAssertFalse(pss.isEmpty, "produced a PSS signature")
        XCTAssertEqual(call("rsaVerify", ["publicPkcs1": pub, "data": data, "signature": pss,
                                          "hash": "SHA-256", "scheme": "RSA-PSS"])["valid"] as? Bool, true,
                       "PSS verifies")

        let plain = Data("a secret message".utf8).base64EncodedString()
        let ct = call("rsaEncrypt", ["publicPkcs1": pub, "data": plain, "hash": "SHA-256"])["data"] as? String ?? ""
        XCTAssertFalse(ct.isEmpty, "OAEP produced ciphertext")
        XCTAssertEqual(call("rsaDecrypt", ["privatePkcs1": priv, "data": ct, "hash": "SHA-256"])["data"] as? String,
                       plain, "RSA-OAEP encrypt → decrypt round-trips")
    }

    func testJwkExportImportPreservesTheKey() {
        let gen = call("rsaGenerate", ["modulusLength": 2048])
        let priv = gen["privatePkcs1"] as? String ?? "", pub = gen["publicPkcs1"] as? String ?? ""

        let jwk = call("rsaExportJwk", ["pkcs1": priv, "type": "private"])["jwk"] as? [String: Any] ?? [:]
        XCTAssertEqual(jwk["kty"] as? String, "RSA")
        XCTAssertNotNil(jwk["n"]); XCTAssertNotNil(jwk["d"]); XCTAssertNotNil(jwk["qi"])

        let reimported = call("rsaImportJwk", ["n": jwk["n"] ?? "", "e": jwk["e"] ?? "", "d": jwk["d"] ?? "",
                                               "p": jwk["p"] ?? "", "q": jwk["q"] ?? "", "dp": jwk["dp"] ?? "",
                                               "dq": jwk["dq"] ?? "", "qi": jwk["qi"] ?? ""])["pkcs1"] as? String ?? ""
        XCTAssertFalse(reimported.isEmpty, "the JWK re-imported to a valid PKCS#1 key")

        // The key that round-tripped through JWK must still produce signatures the ORIGINAL public key
        // verifies — proving the DER INTEGER/SEQUENCE encode+parse is byte-correct.
        let data = Data("round-tripped".utf8).base64EncodedString()
        let sig = call("rsaSign", ["privatePkcs1": reimported, "data": data, "hash": "SHA-256",
                                   "scheme": "RSASSA-PKCS1-v1_5"])["data"] as? String ?? ""
        XCTAssertEqual(call("rsaVerify", ["publicPkcs1": pub, "data": data, "signature": sig,
                                          "hash": "SHA-256", "scheme": "RSASSA-PKCS1-v1_5"])["valid"] as? Bool, true,
                       "a JWK-round-tripped key still signs verifiably (PKCS#1↔JWK DER codec is correct)")
    }
}
