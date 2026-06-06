//
//  BrownBearTheme.swift
//  BrownBear
//
//  The BrownBear design language. A single source of truth for color, metrics, typography,
//  and motion so every surface (browser chrome, tab grid, dashboard, editor) feels like one
//  product. Colors are brand-anchored on the amber/brown palette from the app banner and
//  adapt to light/dark appearance.
//

import UIKit

/// Namespace for all design tokens. Never hardcode a color or spacing value in a view —
/// reach for a token here so the look stays consistent and is tunable in one place.
enum BrownBearTheme {

    // MARK: - Palette

    enum Palette {
        /// Primary brand accent — the amber used for the omnibox cursor, active states, links.
        static let accent = UIColor(dynamicLight: UIColor(hex: 0xE0832F),
                                    dark: UIColor(hex: 0xFFB454))
        /// A lighter amber for highlights and glows.
        static let accentBright = UIColor(hex: 0xFFB454)
        /// Deep brown used in the brand mark and dark chrome.
        static let brandBrown = UIColor(hex: 0x3A2417)

        /// Window/background surface.
        static let background = UIColor(dynamicLight: UIColor(hex: 0xF7F5F2),
                                        dark: UIColor(hex: 0x14110E))
        /// Elevated chrome (omnibox bar, toolbar).
        static let chrome = UIColor(dynamicLight: UIColor(hex: 0xFFFFFF),
                                    dark: UIColor(hex: 0x1F1A15))
        /// The rounded omnibox field fill.
        static let omniboxFill = UIColor(dynamicLight: UIColor(hex: 0xEFEAE4),
                                         dark: UIColor(hex: 0x2A231C))
        /// Tab-grid cell surface.
        static let cell = UIColor(dynamicLight: UIColor(hex: 0xFFFFFF),
                                  dark: UIColor(hex: 0x241D17))

        static let textPrimary = UIColor(dynamicLight: UIColor(hex: 0x1A140E),
                                         dark: UIColor(hex: 0xF5EFE7))
        static let textSecondary = UIColor(dynamicLight: UIColor(hex: 0x6B6058),
                                           dark: UIColor(hex: 0xB6A99C))
        static let separator = UIColor(dynamicLight: UIColor(hex: 0xE2DBD2),
                                       dark: UIColor(hex: 0x322A22))

        static let secure = UIColor(hex: 0x3DA639)     // TLS lock — green
        static let insecure = UIColor(hex: 0xC0392B)   // not secure — red
        static let destructive = UIColor(hex: 0xE5484D)
    }

    // MARK: - Metrics

    enum Metrics {
        static let omniboxHeight: CGFloat = 44
        static let omniboxCornerRadius: CGFloat = 22
        static let chromeHorizontalInset: CGFloat = 12
        static let toolbarHeight: CGFloat = 48
        static let progressBarHeight: CGFloat = 2.5
        static let cellCornerRadius: CGFloat = 16
        static let tabGridSpacing: CGFloat = 14
        static let tabGridInset: CGFloat = 16
        /// Square-ish tab card aspect (width : height of the snapshot area).
        static let tabCardAspect: CGFloat = 0.78
        static let hairline: CGFloat = 1.0 / UIScreen.main.scale
    }

    // MARK: - Typography

    enum Typography {
        static func omnibox() -> UIFont { .systemFont(ofSize: 16, weight: .regular) }
        static func toolbarSymbol() -> UIFont { .systemFont(ofSize: 20, weight: .regular) }
        static func tabTitle() -> UIFont { .systemFont(ofSize: 13, weight: .semibold) }
        static func tabCount() -> UIFont { .systemFont(ofSize: 12, weight: .bold) }
        static func sectionTitle() -> UIFont { .systemFont(ofSize: 17, weight: .bold) }
    }

    // MARK: - Motion

    enum Motion {
        static let standard: TimeInterval = 0.28
        static let quick: TimeInterval = 0.18
        static func spring(_ animations: @escaping () -> Void) {
            UIView.animate(withDuration: standard,
                           delay: 0,
                           usingSpringWithDamping: 0.86,
                           initialSpringVelocity: 0.2,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: animations)
        }
    }
}

// MARK: - UIColor conveniences

extension UIColor {
    /// Build a color from a 0xRRGGBB integer literal.
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }

    /// Build a color that resolves differently in light vs. dark appearance.
    convenience init(dynamicLight light: UIColor, dark: UIColor) {
        self.init { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}
