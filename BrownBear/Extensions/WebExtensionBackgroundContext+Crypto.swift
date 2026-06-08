//
//  WebExtensionBackgroundContext+Crypto.swift
//  BrownBear
//
//  Web Crypto + importScripts backing for the extension background worker's JSContext. JavaScriptCore
//  ships neither, so ScriptCat-derived and crypto-using service workers throw "Can't find variable:
//  crypto" / "Can't find variable: importScripts". We back crypto.getRandomValues / randomUUID /
//  subtle.digest with native secure-random + CryptoKit, and importScripts with a synchronous read of
//  the extension's OWN packaged files.
//
//  Security: importScripts is restricted to the extension's packaged resources — Chrome MV3 service
//  workers forbid loading remote code (the remote-code ban / default CSP `script-src 'self'`), and the
//  real-world consumer here (ScriptCat's service worker) only importScripts its own bundled webpack
//  chunks. A remote URL fails closed (the store can't resolve it → null → the JS shim throws), so this
//  boundary can never become a remote-code-execution vector. (Userscript backgrounds, which legitimately
//  pull remote libraries, gate their own importScripts on @connect in HeadlessScriptRunner instead.)
//
//  Split into its own file so the primary WebExtensionBackgroundContext stays under the length limit;
//  these natives use only `extensionID` (internal) + the public store + Foundation, so a separate-file
//  extension is sufficient.
//

import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    func installCryptoNatives(into context: JSContext) {
        // crypto.subtle.{sign,verify,encrypt,decrypt,deriveBits,generateKey} — symmetric Web Crypto
        // backed by CryptoKit/CommonCrypto. Synchronous (CryptoKit is sync); runs on the context's
        // queue. Params/results are base64 in a small JSON envelope. Asymmetric (ECDSA/RSA) is a
        // follow-up; this covers the common HMAC / AES-GCM / PBKDF2 / HKDF surface extensions use.
        let subtle: @convention(block) (String, String) -> String = { op, paramsJSON in
            let p = ((try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any]) ?? [:]
            return Self.subtleResult(op: op, params: p)
        }
        context.setObject(subtle, forKeyedSubscript: "__bb_subtle" as NSString)

        let cryptoRandom: @convention(block) (Int) -> [Int] = { count in
            let n = max(0, min(count, 65_536))
            return (0..<n).map { _ in Int(UInt8.random(in: 0...255)) }   // secure default RNG
        }
        context.setObject(cryptoRandom, forKeyedSubscript: "__bb_crypto_random" as NSString)

        let cryptoUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        context.setObject(cryptoUUID, forKeyedSubscript: "__bb_crypto_uuid" as NSString)

        let cryptoDigest: @convention(block) (String, [Int]) -> [Int]? = { algo, bytes in
            let data = Data(bytes.map { UInt8(truncatingIfNeeded: $0) })
            switch algo.lowercased().replacingOccurrences(of: "-", with: "") {
            case "sha256": return Array(SHA256.hash(data: data)).map { Int($0) }
            case "sha384": return Array(SHA384.hash(data: data)).map { Int($0) }
            case "sha512": return Array(SHA512.hash(data: data)).map { Int($0) }
            case "sha1": return Array(Insecure.SHA1.hash(data: data)).map { Int($0) }
            default: return nil
            }
        }
        context.setObject(cryptoDigest, forKeyedSubscript: "__bb_crypto_digest" as NSString)

        // importScripts: a service worker loading its OWN packaged files (resolved against the
        // extension via the store). Synchronous (the JS API is sync); this native runs on the context's
        // private serial queue (never main), and the awaited store read signals back from the main
        // actor — a different executor — so the semaphore can't self-deadlock. A remote URL resolves to
        // a package path that the store cannot find, returning null and failing closed (see header).
        let extensionID = self.extensionID
        let importScript: @convention(block) (String) -> String? = { spec in
            let path = Self.packagePath(from: spec)
            guard !path.isEmpty else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var source: String?
            Task {
                source = await BrownBearServices.shared.webExtensionStore.text(extensionID: extensionID, path: path)
                semaphore.signal()
            }
            semaphore.wait()
            return source
        }
        context.setObject(importScript, forKeyedSubscript: "__bb_import_script" as NSString)
    }

    // MARK: - crypto.subtle (symmetric)

    private static func subtleResult(op: String, params p: [String: Any]) -> String {
        func bytes(_ k: String) -> Data { Data(base64Encoded: (p[k] as? String) ?? "") ?? Data() }
        func hash() -> String { ((p["hash"] as? String) ?? "SHA-256").uppercased().replacingOccurrences(of: "-", with: "") }
        func okData(_ d: Data) -> String { Self.encodeSubtle(["data": d.base64EncodedString()]) }
        func okBool(_ b: Bool) -> String { Self.encodeSubtle(["valid": b]) }
        func fail(_ m: String) -> String { Self.encodeSubtle(["error": m]) }
        do {
            switch op {
            case "hmacSign":
                let key = SymmetricKey(data: bytes("key")); let msg = bytes("data")
                switch hash() {
                case "SHA256": return okData(Data(HMAC<SHA256>.authenticationCode(for: msg, using: key)))
                case "SHA384": return okData(Data(HMAC<SHA384>.authenticationCode(for: msg, using: key)))
                case "SHA512": return okData(Data(HMAC<SHA512>.authenticationCode(for: msg, using: key)))
                case "SHA1": return okData(Data(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key)))
                default: return fail("unsupported HMAC hash")
                }
            case "hmacVerify":
                let key = SymmetricKey(data: bytes("key")); let msg = bytes("data"); let sig = bytes("signature")
                switch hash() {
                case "SHA256": return okBool(HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: msg, using: key))
                case "SHA384": return okBool(HMAC<SHA384>.isValidAuthenticationCode(sig, authenticating: msg, using: key))
                case "SHA512": return okBool(HMAC<SHA512>.isValidAuthenticationCode(sig, authenticating: msg, using: key))
                case "SHA1": return okBool(HMAC<Insecure.SHA1>.isValidAuthenticationCode(sig, authenticating: msg, using: key))
                default: return fail("unsupported HMAC hash")
                }
            case "aesGcmEncrypt":
                let sealed = try AES.GCM.seal(bytes("data"), using: SymmetricKey(data: bytes("key")),
                                              nonce: try AES.GCM.Nonce(data: bytes("iv")),
                                              authenticating: bytes("additionalData"))
                return okData(sealed.ciphertext + sealed.tag)   // WebCrypto appends the 16-byte tag
            case "aesGcmDecrypt":
                let combined = bytes("data")
                guard combined.count >= 16 else { return fail("ciphertext too short") }
                let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: bytes("iv")),
                                                ciphertext: combined.prefix(combined.count - 16),
                                                tag: combined.suffix(16))
                return okData(try AES.GCM.open(box, using: SymmetricKey(data: bytes("key")),
                                               authenticating: bytes("additionalData")))
            case "pbkdf2":
                return Self.pbkdf2(password: bytes("password"), salt: bytes("salt"),
                                   iterations: (p["iterations"] as? Int) ?? 100_000,
                                   bits: (p["length"] as? Int) ?? 256, hash: hash()).map(okData) ?? fail("PBKDF2 failed")
            case "hkdf":
                let ikm = SymmetricKey(data: bytes("ikm")); let salt = bytes("salt"); let info = bytes("info")
                let n = ((p["length"] as? Int) ?? 256) / 8
                func raw(_ k: SymmetricKey) -> String { okData(k.withUnsafeBytes { Data($0) }) }
                switch hash() {
                case "SHA256": return raw(HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: n))
                case "SHA384": return raw(HKDF<SHA384>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: n))
                case "SHA512": return raw(HKDF<SHA512>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: n))
                default: return fail("unsupported HKDF hash")
                }
            case "generateAesKey":
                let key = SymmetricKey(size: SymmetricKeySize(bitCount: (p["length"] as? Int) ?? 256))
                return okData(key.withUnsafeBytes { Data($0) })
            default:
                return fail("unsupported subtle op: \(op)")
            }
        } catch {
            return fail(String(describing: error))
        }
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, bits: Int, hash: String) -> Data? {
        let prf: CCPseudoRandomAlgorithm
        switch hash {
        case "SHA1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case "SHA256": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case "SHA384": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case "SHA512": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        default: return nil
        }
        let count = max(1, bits / 8)
        var out = Data(count: count)
        let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         prf, UInt32(iterations),
                                         outPtr.bindMemory(to: UInt8.self).baseAddress, count)
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    private static func encodeSubtle(_ dict: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"error\":\"encode failed\"}"
    }

    /// Strip a chrome-extension://<id>/ prefix (and any leading slash) so the remainder is a package
    /// path the store can resolve.
    private static func packagePath(from spec: String) -> String {
        var path = spec
        if let range = path.range(of: "://") {
            // chrome-extension://<id>/rest → rest
            let afterScheme = path[range.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                path = String(afterScheme[afterScheme.index(after: slash)...])
            }
        }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}
