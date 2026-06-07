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

import CryptoKit
import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    func installCryptoNatives(into context: JSContext) {
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
