//
//  WebExtensionIconResolver.swift
//  BrownBear
//
//  Picks which packaged icon file represents an extension's action/toolbar entry. Both the dashboard's
//  Extensions list and the browser's quick-menu ("•••") extension rows resolve icons through here, so an
//  extension shows the SAME real icon in both surfaces instead of one of them falling back to the generic
//  puzzle glyph. Pure (table-tested in ExtensionIconPickTests); the caller loads the returned path from
//  the extension package.
//

import Foundation

enum WebExtensionIconResolver {

    /// Prefer the action/toolbar icon (what users associate with the extension), else the manifest's
    /// top-level `icons`. `nil` when the manifest declares neither (the caller then shows the puzzle
    /// placeholder). Chrome uses the same fallback for the toolbar action.
    static func bestIconPath(_ manifest: WebExtensionManifest?) -> String? {
        guard let manifest else { return nil }
        return pickIconPath(from: manifest.action?.defaultIcon) ?? pickIconPath(from: manifest.icons)
    }

    /// Pick a path from a `size → path` icon map: a crisp size near 64 (sharp at a 28pt view @2–3x), else
    /// the largest available. Empty paths are ignored (a `"48": ""` entry would otherwise be "chosen" and
    /// then fail to load, dropping the row to the generic glyph); a nil/empty map returns nil.
    static func pickIconPath(from icons: [String: String]?) -> String? {
        guard let icons else { return nil }
        let sized = icons.compactMap { key, value -> (size: Int, path: String)? in
            value.isEmpty ? nil : (Int(key) ?? 0, value)
        }
        guard !sized.isEmpty else { return nil }
        let inRange = sized.filter { $0.size >= 32 && $0.size <= 128 }
        let chosen = inRange.min { abs($0.size - 64) < abs($1.size - 64) }
            ?? sized.max { $0.size < $1.size }
        return chosen?.path
    }
}
