//
//  BrownBearTheme.swift
//  BrownBear
//
//  The BrownBear design language — a single source of truth for color, spacing, elevation,
//  typography, and motion so every surface (browser chrome, tab grid, dashboard, editor) feels
//  like one product. Colors are SEMANTIC ROLES (not raw hues): surfaces, accent/actions, text,
//  icons, borders, status. The amber/brown brand is anchored throughout and adapts to light/dark.
//
//  Migration note: the visual overhaul moves views onto these roles component-by-component. The
//  pre-role names (`background`, `chrome`, `omniboxFill`, `cell`, `separator`) remain as aliases
//  pointing at the new roles so not-yet-migrated call sites keep compiling unchanged.
//

import UIKit

/// Namespace for all design tokens. Never hardcode a color or spacing value in a view — reach for
/// a token here so the look stays consistent and is tunable in one place.
enum BrownBearTheme {

    // MARK: - Palette (semantic roles)

    enum Palette {

        // Accent / actions — amber is the action color.
        /// Primary brand accent — cursor, active/selected glyphs, links, primary CTA fill.
        static let accent = UIColor(dynamicLight: UIColor(hex: 0xE0832F), dark: UIColor(hex: 0xFFB454))
        /// A brighter amber for glows and the progress-bar head.
        static let accentBright = UIColor(hex: 0xFFB454)
        /// Pressed/highlighted state of an accent fill.
        static let accentPressed = UIColor(dynamicLight: UIColor(hex: 0xC56E1F), dark: UIColor(hex: 0xE0832F))
        /// Soft accent wash — selected tiles, badges, hover backings.
        static let accentSoft = UIColor(dynamicLight: UIColor(hex: 0xE0832F, alpha: 0.14),
                                        dark: UIColor(hex: 0xFFB454, alpha: 0.18))
        /// Text/glyph drawn on top of an accent fill.
        static let onAccent = UIColor(dynamicLight: UIColor(hex: 0xFFFFFF), dark: UIColor(hex: 0x1A140E))
        /// Deep brown brand mark color.
        static let brandBrown = UIColor(hex: 0x3A2417)

        // Surfaces (layered elevation).
        /// Window background.
        static let surfaceBase = UIColor(dynamicLight: UIColor(hex: 0xF7F5F2), dark: UIColor(hex: 0x14110E))
        /// Elevated chrome (top bar, bottom toolbar).
        static let surfaceRaised = UIColor(dynamicLight: UIColor(hex: 0xFFFFFF), dark: UIColor(hex: 0x1F1A15))
        /// Omnibox pill fill.
        static let surfaceField = UIColor(dynamicLight: UIColor(hex: 0xEFEAE4), dark: UIColor(hex: 0x2A231C))
        /// Cards (tab cells, menu list container, install card).
        static let surfaceCard = UIColor(dynamicLight: UIColor(hex: 0xFFFFFF), dark: UIColor(hex: 0x241D17))
        /// Sunken backing (tab thumbnail area, NTP tiles).
        static let surfaceCardSunken = UIColor(dynamicLight: UIColor(hex: 0xF0ECE6), dark: UIColor(hex: 0x1A150F))
        /// Dimming scrim behind sheets / the tab grid.
        static let surfaceScrim = UIColor(dynamicLight: UIColor(hex: 0x000000, alpha: 0.40),
                                          dark: UIColor(hex: 0x000000, alpha: 0.50))
        /// Tint backing for a tab card's blurred header strip.
        static let surfaceMenuHeader = UIColor(dynamicLight: UIColor(hex: 0xFBF8F4), dark: UIColor(hex: 0x2A231C))

        // Text.
        static let textPrimary = UIColor(dynamicLight: UIColor(hex: 0x1A140E), dark: UIColor(hex: 0xF5EFE7))
        static let textSecondary = UIColor(dynamicLight: UIColor(hex: 0x6B6058), dark: UIColor(hex: 0xB6A99C))
        static let textTertiary = UIColor(dynamicLight: UIColor(hex: 0x9A8E82), dark: UIColor(hex: 0x7E7165))

        // Icons — resting glyphs are NEUTRAL; accent is reserved for active/selected/pressed.
        static let iconPrimary = UIColor(dynamicLight: UIColor(hex: 0x4A4038), dark: UIColor(hex: 0xD9CFC4))
        static let iconActive = accent
        static let iconDisabled = UIColor(dynamicLight: UIColor(hex: 0x4A4038, alpha: 0.4),
                                          dark: UIColor(hex: 0xD9CFC4, alpha: 0.4))

        // Borders & dividers.
        static let borderSubtle = UIColor(dynamicLight: UIColor(hex: 0xE2DBD2), dark: UIColor(hex: 0x322A22))
        static let borderStrong = UIColor(dynamicLight: UIColor(hex: 0xD2C7BB), dark: UIColor(hex: 0x42382E))
        static let borderSelected = accent

        // Status.
        static let secure = UIColor(hex: 0x3DA639)     // TLS lock — green
        static let insecure = UIColor(hex: 0xC0392B)   // not secure — red
        static let warning = accent
        static let destructive = UIColor(hex: 0xE5484D)

        // MARK: Pre-role aliases (migrated away component-by-component)
        static let background = surfaceBase
        static let chrome = surfaceRaised
        static let omniboxFill = surfaceField
        static let cell = surfaceCard
        static let separator = borderSubtle
    }

    // MARK: - Spacing (8pt grid)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Elevation / shadow

    /// A two-opacity shadow style; dark mode needs heavier shadow to read.
    struct ShadowStyle {
        let opacityLight: Float
        let opacityDark: Float
        let radius: CGFloat
        let offset: CGSize
        func opacity(for traits: UITraitCollection) -> Float {
            traits.userInterfaceStyle == .dark ? opacityDark : opacityLight
        }
        /// Apply to a layer (caller sets `shadowPath` in `layoutSubviews` for performance).
        func apply(to layer: CALayer, traits: UITraitCollection) {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = opacity(for: traits)
            layer.shadowRadius = radius
            layer.shadowOffset = offset
        }
    }

    enum Elevation {
        /// Tight contact shadow (resting chrome, pills).
        static let level1 = ShadowStyle(opacityLight: 0.10, opacityDark: 0.40, radius: 2, offset: CGSize(width: 0, height: 1))
        /// Soft ambient shadow (cards, raised sheets) — stack with level1 for depth.
        static let level2 = ShadowStyle(opacityLight: 0.08, opacityDark: 0.30, radius: 16, offset: CGSize(width: 0, height: 4))
    }

    // MARK: - Metrics

    enum Metrics {
        static let omniboxHeight: CGFloat = 44
        static let omniboxCornerRadius: CGFloat = 22
        static let chromeHorizontalInset: CGFloat = 12
        static let toolbarHeight: CGFloat = 48
        static let progressBarHeight: CGFloat = 3.0
        static let cellCornerRadius: CGFloat = 16
        static let tabGridSpacing: CGFloat = 14
        static let tabGridInset: CGFloat = 16
        /// Square-ish tab card aspect (width : height of the snapshot area).
        static let tabCardAspect: CGFloat = 0.78
        static let hairline: CGFloat = 1.0 / UIScreen.main.scale
    }

    // MARK: - Typography

    enum Typography {
        /// A Dynamic-Type-scaled system font. `maximumPointSize` (0 = uncapped) clamps growth at
        /// large accessibility sizes so dense chrome stays usable.
        static func scaled(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle,
                           maximumPointSize: CGFloat = 0) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let metrics = UIFontMetrics(forTextStyle: style)
            return maximumPointSize > 0
                ? metrics.scaledFont(for: base, maximumPointSize: maximumPointSize)
                : metrics.scaledFont(for: base)
        }

        // New Dynamic-Type-backed semantic styles (components adopt these in their overhaul PRs).
        static func titleScaled() -> UIFont { scaled(17, .semibold, .headline) }
        static func bodyScaled() -> UIFont { scaled(16, .regular, .body) }
        static func captionScaled() -> UIFont { scaled(13, .semibold, .caption1) }
        static func captionBoldScaled() -> UIFont { scaled(12, .bold, .caption2) }
        static func cta() -> UIFont { scaled(16, .semibold, .callout) }
        static func omniboxScaled() -> UIFont { scaled(16, .regular, .body, maximumPointSize: 24) }

        // Pre-overhaul styles — fixed sizes, kept behavior-identical until consumers migrate.
        static func omnibox() -> UIFont { .systemFont(ofSize: 16, weight: .regular) }
        static func toolbarSymbol() -> UIFont { .systemFont(ofSize: 20, weight: .regular) }
        static func tabTitle() -> UIFont { .systemFont(ofSize: 13, weight: .semibold) }
        static func tabCount() -> UIFont { .systemFont(ofSize: 12, weight: .bold) }
        static func sectionTitle() -> UIFont { .systemFont(ofSize: 17, weight: .bold) }

        /// A Dynamic-Type-scaled symbol configuration for toolbar glyphs (grows with text size).
        static func symbol(pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage.SymbolConfiguration {
            let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: pointSize)
            return UIImage.SymbolConfiguration(pointSize: scaled, weight: weight, scale: .medium)
        }
    }

    // MARK: - Motion

    enum Motion {
        static let standard: TimeInterval = 0.28
        static let quick: TimeInterval = 0.18
        static let crossfade: TimeInterval = 0.10
        static let sheetSpringDamping: CGFloat = 0.82
        static let sheetSpringDuration: TimeInterval = 0.42

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
