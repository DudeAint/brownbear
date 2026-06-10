//
//  WebExtensionImageBridge.swift
//  BrownBear
//
//  Backs `new Image(); img.src = url` in the headless MV2 background. A JSContext can't load/decode
//  pixels, so when a background page sets an image source we fetch the bytes natively and hand back a
//  `data:` URL the page can render — the canvas stub's `toDataURL()` then returns that real image instead
//  of a placeholder. This is what makes Violentmonkey's script icons real: VM's icon loader does
//  `new Image()` → draw onto a canvas → `toDataURL()`, all in the background, and the resulting data-URI
//  is sent to the popup/options.
//
//  Sources, in order: `data:` (passthrough, must be an image), `chrome-extension://<thisExt>/…` (read the
//  packaged resource), `http(s)` (SSRF-gated fetch). Capped at 5 MB; the host is checked against the same
//  loopback/private/link-local blocklist as chrome.downloads (CLAUDE.md §5).
//

import Foundation
import UIKit

enum WebExtensionImageBridge {

    private static let maxBytes = 5 * 1024 * 1024

    /// Resolve `urlString` to `{dataUrl, width, height}`, or `{error}`. Safe to call off the main actor.
    static func fetchImageDataURL(urlString: String, extensionID: String) async -> [String: Any] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "empty image url"] }

        // data: — already a data-URI; pass it through (only if it's an image).
        if trimmed.hasPrefix("data:") {
            guard trimmed.hasPrefix("data:image/") else { return ["error": "not an image data url"] }
            let dims = Self.dimensions(ofDataURL: trimmed)
            return ["dataUrl": trimmed, "width": dims.width, "height": dims.height]
        }

        guard let url = URL(string: trimmed) else { return ["error": "invalid image url"] }
        let scheme = url.scheme?.lowercased()

        // {chrome,moz}-extension://<thisExt>/path — a packaged icon. Read it from the store (this ext only).
        if WebExtensionSchemeHandler.isExtensionScheme(scheme) {
            guard url.host == extensionID else { return ["error": "cross-extension image"] }
            var path = url.path
            while path.hasPrefix("/") { path.removeFirst() }
            guard !path.isEmpty,
                  let data = await BrownBearServices.shared.webExtensionStore.file(extensionID: extensionID, path: path),
                  data.count <= maxBytes else { return ["error": "packaged image not found"] }
            return Self.result(data: data, mime: Self.mime(forPath: path))
        }

        // http(s) — SSRF-gated fetch.
        guard scheme == "http" || scheme == "https" else { return ["error": "unsupported image scheme"] }
        guard !WebExtensionFetchSecurity.isBlockedHost(url.host) else {
            return ["error": "refusing to load an image from a private/loopback host"]
        }
        let session = WebExtensionFetchSecurity.downloadGuardedSession()
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= maxBytes else { return ["error": "image too large"] }
            let mime = response.mimeType ?? "image/png"
            guard mime.hasPrefix("image/") else { return ["error": "not an image"] }
            return Self.result(data: data, mime: mime)
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func result(data: Data, mime: String) -> [String: Any] {
        let image = UIImage(data: data)
        return ["dataUrl": "data:\(mime);base64,\(data.base64EncodedString())",
                "width": Int(image?.size.width ?? 0), "height": Int(image?.size.height ?? 0)]
    }

    private static func dimensions(ofDataURL dataURL: String) -> (width: Int, height: Int) {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]),
                              options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else { return (0, 0) }
        return (Int(image.size.width), Int(image.size.height))
    }

    private static func mime(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}
