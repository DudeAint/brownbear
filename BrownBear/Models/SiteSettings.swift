//
//  SiteSettings.swift
//  BrownBear
//
//  Per-site preferences remembered across visits, keyed by host. Each field is optional: nil means
//  "follow the global default", a concrete value means "this site is pinned to this choice". This is
//  what powers Orion-style Website Settings / Brave per-site Shields: request-desktop, page zoom,
//  content-blocking override, and a per-site JavaScript switch that persist per host.
//

import Foundation

struct SiteSettings: Codable, Equatable {

    /// Request the desktop site for this host. nil = use the app default (mobile).
    var desktopUA: Bool?

    /// Pinned page zoom (WKWebView.pageZoom multiplier, e.g. 1.25). nil = default 1.0.
    var zoom: Double?

    /// Per-site content-blocking override. true = force-block, false = allow (disable shields on a
    /// broken site), nil = follow the global blocking setting.
    var blockContent: Bool?

    /// Per-site JavaScript switch. nil = default (enabled).
    var allowJavaScript: Bool?

    /// An entry that pins nothing — equivalent to "no stored settings for this host".
    static let none = SiteSettings()

    /// Whether every field is at its default; such an entry can be pruned from the store.
    var isEmpty: Bool {
        desktopUA == nil && zoom == nil && blockContent == nil && allowJavaScript == nil
    }
}
