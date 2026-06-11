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

    /// The Chrome version we tell the CRX endpoint we are. Google's update server gates each item on its
    /// manifest `minimum_chrome_version`: ask as too OLD a Chrome and a modern extension (e.g. uBlock
    /// Origin Lite, which needs newer than 120) comes back 204 No Content — the "some extensions just say
    /// failed to get from the store" bug, while older-requirement ones download fine. We declare an
    /// arbitrarily-high version so nothing is ever gated out; the server accepts it and still serves the
    /// latest compatible package. (Verified live: id ddkj… returns 204 at prodversion=120 but 302 to a
    /// real CRX at 9999, while Tampermonkey/Dark Reader/Bitwarden succeed at both.)
    static let defaultChromeVersion = "9999.0.0.0"

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
        if let http = response as? HTTPURLResponse {
            // 204 No Content = the endpoint has no package for this id. With our high prodversion that's
            // no longer a "your Chrome is too old" gate, so it means the id is wrong or the item is
            // unlisted / region-locked / removed — say so plainly instead of a bare "empty package".
            if http.statusCode == 204 {
                throw BrownBearError.navigationFailed("the Chrome Web Store has no downloadable package "
                    + "for \(extensionID). The id may be wrong, or the item may be unlisted or removed.")
            }
            if !(200...299).contains(http.statusCode) {
                throw BrownBearError.navigationFailed("the store returned HTTP \(http.statusCode) for \(extensionID)")
            }
        }
        guard !data.isEmpty else {
            throw BrownBearError.metadataParseFailed("the store returned an empty package for \(extensionID)")
        }
        return data
    }
}
