//
//  ChromeWebStore.swift
//  BrownBear
//
//  Direct install from the Chrome Web Store — the Orion/Gear-style "paste a store link, get the
//  extension" flow. Given a store URL or a bare 32-char extension id, it hits Google's public CRX
//  download endpoint (the same one Chrome itself uses for on-demand installs), which 302-redirects
//  to a CRX3 package; `WebExtensionArchive` already strips the CRX header and reads the ZIP, so the
//  bytes flow straight into the normal install path.
//

import Foundation

enum ChromeWebStore {

    /// A plausible recent Chrome version — the endpoint requires one to serve a package.
    static let defaultChromeVersion = "120.0.0.0"

    /// Pull a 32-char extension id (lowercase a–p) out of a store URL or a bare id string.
    static func extensionID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(trimmed) { return trimmed }
        guard let url = URL(string: trimmed) else { return nil }
        // Both chrome.google.com/webstore/detail/<slug>/<id> and the newer
        // chromewebstore.google.com/detail/<slug>/<id> put the id as a path component.
        for component in url.pathComponents.reversed() where isExtensionID(component) {
            return component
        }
        return nil
    }

    static func isExtensionID(_ string: String) -> Bool {
        string.count == 32 && string.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The CRX download URL for an extension id. The `x` parameter is a percent-encoded blob of
    /// nested key=value pairs, so we encode it ourselves (URLComponents would leave `&`/`=` raw).
    static func downloadURL(extensionID: String, chromeVersion: String = defaultChromeVersion) -> URL? {
        guard isExtensionID(extensionID) else { return nil }
        let x = "id=\(extensionID)&installsource=ondemand&uc"
        let encodedX = x.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? x
        let string = "https://clients2.google.com/service/update2/crx"
            + "?response=redirect&acceptformat=crx2,crx3"
            + "&prodversion=\(chromeVersion)&x=\(encodedX)"
        return URL(string: string)
    }

    /// Download the CRX package bytes for an extension id / store URL.
    static func downloadCRX(forInput input: String,
                            session: URLSession = .shared,
                            chromeVersion: String = defaultChromeVersion) async throws -> Data {
        guard let extensionID = extensionID(from: input) else {
            throw BrownBearError.metadataParseFailed("that doesn't look like a Chrome Web Store link or extension id")
        }
        guard let url = downloadURL(extensionID: extensionID, chromeVersion: chromeVersion) else {
            throw BrownBearError.metadataParseFailed("couldn't build a download URL for \(extensionID)")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BrownBearError.navigationFailed("the store returned HTTP \(http.statusCode) for \(extensionID)")
        }
        guard !data.isEmpty else {
            throw BrownBearError.metadataParseFailed("the store returned an empty package for \(extensionID)")
        }
        return data
    }
}
