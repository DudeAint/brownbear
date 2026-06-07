//
//  EdgeAddons.swift
//  BrownBear
//
//  Direct install from the Microsoft Edge Add-ons store. Edge ships Chromium-format CRX packages from
//  its own on-demand endpoint (the same family as Chrome's), so once the bytes are fetched they flow
//  through the exact same `WebExtensionArchive` → `WebExtensionStore.install` path as Chrome.
//

import Foundation

enum EdgeAddons {

    /// Pull a 32-char extension id (lowercase a–p) out of an Edge Add-ons URL or a bare id string.
    static func extensionID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(trimmed) { return trimmed }
        guard let url = URL(string: trimmed) else { return nil }
        // microsoftedge.microsoft.com/addons/detail/<slug>/<id>
        for component in url.pathComponents.reversed() where isExtensionID(component) { return component }
        return nil
    }

    static func isExtensionID(_ string: String) -> Bool {
        string.count == 32 && string.allSatisfy { ("a"..."p").contains($0) }
    }

    /// Edge's on-demand CRX endpoint for an extension id. `x` is a percent-encoded blob of nested
    /// key=value pairs, so we encode it ourselves (URLComponents would leave `&`/`=` raw).
    static func downloadURL(extensionID: String) -> URL? {
        guard isExtensionID(extensionID) else { return nil }
        let x = "id=\(extensionID)&installsource=ondemand&uc"
        let encodedX = x.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? x
        let string = "https://edge.microsoft.com/extensionwebstorebase/v1/crx"
            + "?response=redirect&prod=chromiumcrx&prodchannel=&x=\(encodedX)"
        return URL(string: string)
    }

    /// Download the CRX package bytes for an Edge extension id.
    static func downloadCRX(id: String, session: URLSession = .shared) async throws -> Data {
        guard let url = downloadURL(extensionID: id) else {
            throw BrownBearError.metadataParseFailed("that doesn't look like an Edge Add-ons link or id")
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BrownBearError.navigationFailed("the Edge store returned HTTP \(http.statusCode) for \(id)")
        }
        guard !data.isEmpty else {
            throw BrownBearError.metadataParseFailed("the Edge store returned an empty package for \(id)")
        }
        return data
    }
}
