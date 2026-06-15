//
//  WebExtensionBackgroundContext+CryptoRSA.swift
//  BrownBear
//
//  crypto.subtle RSA (RSASSA-PKCS1-v1_5, RSA-PSS, RSA-OAEP) for the extension background worker's
//  JSContext — the asymmetric follow-up to the symmetric + ECDSA surface in +Crypto.swift. (Page,
//  popup, options and content-script contexts already get full native RSA from WebKit; only the
//  headless JSContext lacked it, so a service worker doing RSA crypto threw.)
//
//  Keys are carried JS-side as base64 of their PKCS#1 DER — exactly Apple SecKey's external
//  representation for `kSecAttrKeyTypeRSA` (RSAPublicKey / RSAPrivateKey SEQUENCEs of INTEGERs), so we
//  reconstruct the SecKey per call with `SecKeyCreateWithData`. JWK import/export converts between that
//  PKCS#1 and the JWK integer members with a minimal DER codec below; SPKI/PKCS8 are deferred (the same
//  scope ECDSA ships today). All ops are pure Security-framework calls — no device/runtime dependency,
//  so the round-trips are unit-tested directly.
//

import Foundation
import Security

extension WebExtensionBackgroundContext {

    /// RSA generate / sign / verify / encrypt / decrypt + JWK key import-export. Dispatched from
    /// `subtleResult`. `op` names the operation; `params` carries base64 inputs + the algorithm/hash.
    static func rsa(op: String, params p: [String: Any]) -> String {
        func b64(_ k: String) -> Data { Data(base64Encoded: (p[k] as? String) ?? "") ?? Data() }
        func str(_ k: String) -> String { (p[k] as? String) ?? "" }
        func hash() -> String { (str("hash").isEmpty ? "SHA-256" : str("hash")).uppercased().replacingOccurrences(of: "-", with: "") }
        func fail(_ m: String) -> String { encodeSubtle(["error": m]) }
        do {
            switch op {
            case "rsaGenerate":
                let bits = (p["modulusLength"] as? Int) ?? 2048
                let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
                var error: Unmanaged<CFError>?
                guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
                      let pub = SecKeyCopyPublicKey(priv) else { return fail("RSA generateKey failed") }
                let privDER = try external(priv), pubDER = try external(pub)
                return encodeSubtle(["privatePkcs1": privDER.base64EncodedString(),
                                     "publicPkcs1": pubDER.base64EncodedString()])

            case "rsaSign":
                let key = try secKey(b64("privatePkcs1"), isPublic: false)
                guard let algo = signAlgorithm(scheme: str("scheme"), hash: hash()) else { return fail("unsupported RSA sign params") }
                var error: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(key, algo, b64("data") as CFData, &error) as Data? else {
                    return fail("RSA sign failed: \(cfError(error))")
                }
                return encodeSubtle(["data": sig.base64EncodedString()])

            case "rsaVerify":
                let key = try secKey(b64("publicPkcs1"), isPublic: true)
                guard let algo = signAlgorithm(scheme: str("scheme"), hash: hash()) else { return fail("unsupported RSA verify params") }
                let valid = SecKeyVerifySignature(key, algo, b64("data") as CFData, b64("signature") as CFData, nil)
                return encodeSubtle(["valid": valid])

            case "rsaEncrypt":
                let key = try secKey(b64("publicPkcs1"), isPublic: true)
                guard let algo = oaepAlgorithm(hash: hash()) else { return fail("unsupported RSA-OAEP hash") }
                var error: Unmanaged<CFError>?
                guard let out = SecKeyCreateEncryptedData(key, algo, b64("data") as CFData, &error) as Data? else {
                    return fail("RSA-OAEP encrypt failed: \(cfError(error))")
                }
                return encodeSubtle(["data": out.base64EncodedString()])

            case "rsaDecrypt":
                let key = try secKey(b64("privatePkcs1"), isPublic: false)
                guard let algo = oaepAlgorithm(hash: hash()) else { return fail("unsupported RSA-OAEP hash") }
                var error: Unmanaged<CFError>?
                guard let out = SecKeyCreateDecryptedData(key, algo, b64("data") as CFData, &error) as Data? else {
                    return fail("RSA-OAEP decrypt failed: \(cfError(error))")
                }
                return encodeSubtle(["data": out.base64EncodedString()])

            case "rsaImportJwk":
                let n = base64urlDecode(str("n")), e = base64urlDecode(str("e"))
                let dStr = str("d")
                if !dStr.isEmpty {
                    let der = pkcs1PrivateKey(n: n, e: e, d: base64urlDecode(dStr),
                                              p: base64urlDecode(str("p")), q: base64urlDecode(str("q")),
                                              dp: base64urlDecode(str("dp")), dq: base64urlDecode(str("dq")),
                                              qi: base64urlDecode(str("qi")))
                    _ = try secKey(der, isPublic: false)   // validate
                    return encodeSubtle(["pkcs1": der.base64EncodedString(), "type": "private"])
                }
                let der = pkcs1PublicKey(n: n, e: e)
                _ = try secKey(der, isPublic: true)        // validate
                return encodeSubtle(["pkcs1": der.base64EncodedString(), "type": "public"])

            case "rsaExportJwk":
                let der = b64("pkcs1")
                guard let ints = parseDERSequenceIntegers(Array(der)) else { return fail("RSA exportKey: bad key") }
                if str("type") == "private" {
                    // RSAPrivateKey: version, n, e, d, p, q, dp, dq, qi
                    guard ints.count >= 9 else { return fail("RSA exportKey: short private key") }
                    let jwk: [String: Any] = ["kty": "RSA",
                        "n": base64urlEncode(Data(ints[1])), "e": base64urlEncode(Data(ints[2])),
                        "d": base64urlEncode(Data(ints[3])), "p": base64urlEncode(Data(ints[4])),
                        "q": base64urlEncode(Data(ints[5])), "dp": base64urlEncode(Data(ints[6])),
                        "dq": base64urlEncode(Data(ints[7])), "qi": base64urlEncode(Data(ints[8]))]
                    return encodeSubtle(["jwk": jwk])
                }
                guard ints.count >= 2 else { return fail("RSA exportKey: short public key") }
                let jwk: [String: Any] = ["kty": "RSA",
                    "n": base64urlEncode(Data(ints[0])), "e": base64urlEncode(Data(ints[1]))]
                return encodeSubtle(["jwk": jwk])

            default:
                return fail("unsupported rsa op: \(op)")
            }
        } catch let err as RSAError {
            return fail(err.message)
        } catch {
            return fail(String(describing: error))
        }
    }

    // MARK: - SecKey helpers

    private struct RSAError: Error { let message: String }

    /// Rebuild a SecKey from its PKCS#1 DER (RSAPublicKey / RSAPrivateKey), Apple's RSA external rep.
    private static func secKey(_ pkcs1: Data, isPublic: Bool) throws -> SecKey {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                      kSecAttrKeyClass: isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw RSAError(message: "invalid RSA key: \(cfError(error))")
        }
        return key
    }

    private static func external(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw RSAError(message: "key export failed: \(cfError(error))")
        }
        return data
    }

    private static func cfError(_ e: Unmanaged<CFError>?) -> String {
        guard let e else { return "unknown" }
        return CFErrorCopyDescription(e.takeRetainedValue()) as String? ?? "error"
    }

    private static func signAlgorithm(scheme: String, hash: String) -> SecKeyAlgorithm? {
        let pss = scheme.uppercased().contains("PSS")
        switch (pss, hash) {
        case (false, "SHA256"): return .rsaSignatureMessagePKCS1v15SHA256
        case (false, "SHA384"): return .rsaSignatureMessagePKCS1v15SHA384
        case (false, "SHA512"): return .rsaSignatureMessagePKCS1v15SHA512
        case (false, "SHA1"): return .rsaSignatureMessagePKCS1v15SHA1
        case (true, "SHA256"): return .rsaSignatureMessagePSSSHA256
        case (true, "SHA384"): return .rsaSignatureMessagePSSSHA384
        case (true, "SHA512"): return .rsaSignatureMessagePSSSHA512
        default: return nil
        }
    }

    private static func oaepAlgorithm(hash: String) -> SecKeyAlgorithm? {
        switch hash {
        case "SHA256": return .rsaEncryptionOAEPSHA256
        case "SHA384": return .rsaEncryptionOAEPSHA384
        case "SHA512": return .rsaEncryptionOAEPSHA512
        case "SHA1": return .rsaEncryptionOAEPSHA1
        default: return nil
        }
    }

    // MARK: - Minimal DER (PKCS#1 ↔ JWK)

    /// DER length octets: short form (<128) or long form (0x8N + N big-endian bytes).
    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var len = n, bytes: [UInt8] = []
        while len > 0 { bytes.insert(UInt8(len & 0xFF), at: 0); len >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    /// A DER INTEGER from a big-endian unsigned magnitude: strip leading zero bytes, then prepend one
    /// 0x00 if the high bit is set (so it stays a positive two's-complement integer).
    private static func derInteger(_ magnitude: Data) -> [UInt8] {
        var bytes = Array(magnitude)
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return [0x02] + derLength(bytes.count) + bytes
    }

    private static func derSequence(_ elements: [[UInt8]]) -> [UInt8] {
        let body = elements.flatMap { $0 }
        return [0x30] + derLength(body.count) + body
    }

    private static func pkcs1PublicKey(n: Data, e: Data) -> Data {
        Data(derSequence([derInteger(n), derInteger(e)]))
    }

    private static func pkcs1PrivateKey(n: Data, e: Data, d: Data, p: Data, q: Data,
                                        dp: Data, dq: Data, qi: Data) -> Data {
        Data(derSequence([derInteger(Data([0])), derInteger(n), derInteger(e), derInteger(d),
                          derInteger(p), derInteger(q), derInteger(dp), derInteger(dq), derInteger(qi)]))
    }

    /// Parse a top-level DER SEQUENCE of INTEGERs → each integer's big-endian magnitude (leading 0x00
    /// sign byte stripped). Returns nil if the bytes aren't a well-formed SEQUENCE-of-INTEGERs.
    private static func parseDERSequenceIntegers(_ bytes: [UInt8]) -> [[UInt8]]? {
        var i = 0
        func readLen() -> Int? {
            guard i < bytes.count else { return nil }
            let first = bytes[i]; i += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
            var len = 0
            for _ in 0..<count { len = (len << 8) | Int(bytes[i]); i += 1 }
            return len
        }
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }   // SEQUENCE
        i += 1
        guard let seqLen = readLen(), i + seqLen <= bytes.count else { return nil }
        let end = i + seqLen
        var ints: [[UInt8]] = []
        while i < end {
            guard bytes[i] == 0x02 else { return nil }   // INTEGER
            i += 1
            guard let len = readLen(), i + len <= end else { return nil }
            var value = Array(bytes[i..<(i + len)])
            i += len
            while value.count > 1 && value.first == 0 { value.removeFirst() }   // strip the sign byte
            ints.append(value)
        }
        return ints
    }
}
