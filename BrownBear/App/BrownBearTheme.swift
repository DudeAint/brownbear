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

    // MARK: - Theme family

    /// The color family the tokens currently resolve from, derived from `AppSettings.theme`. `clean` is
    /// the default white/graphite look; `og` is the original warm amber/brown look. Both still carry
    /// light + dark variants — `themed(...)` picks a hex by (this family × the trait's light/dark).
    static var activeFamily: ThemeFamily { AppSettings.theme.family }

    /// Build a token that resolves by BOTH the active family (clean/og) AND the appearance (light/dark).
    /// The dynamic provider re-runs on a light/dark trait change automatically; a family change at the
    /// SAME light/dark is picked up because `ThemeController` re-applies colors on `.brownBearThemeChanged`
    /// (and forces a trait cycle for the forced Light/Dark cases).
    static func themed(cleanLight: UInt32, cleanDark: UInt32, ogLight: UInt32, ogDark: UInt32) -> UIColor {
        UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch activeFamily {
            case .clean: return UIColor(hex: dark ? cleanDark : cleanLight)
            case .og:    return UIColor(hex: dark ? ogDark : ogLight)
            }
        }
    }

    /// Same, with a single uniform alpha applied to whichever variant is picked.
    static func themed(cleanLight: UInt32, cleanDark: UInt32, ogLight: UInt32, ogDark: UInt32,
                       alpha: CGFloat) -> UIColor {
        UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch activeFamily {
            case .clean: return UIColor(hex: dark ? cleanDark : cleanLight, alpha: alpha)
            case .og:    return UIColor(hex: dark ? ogDark : ogLight, alpha: alpha)
            }
        }
    }

    // MARK: - Palette (semantic roles)

    // CLEAN family = the white/graphite default (color comes from content, not chrome). OG family =
    // the original warm amber/brown look, preserved byte-for-byte so the "OG BrownBear" theme is
    // identical to the old app. Status hues (secure/insecure/destructive) are shared across families.
    enum Palette {

        // Accent / actions.
        //   clean → graphite (near-black on light, near-white on dark): the monochrome action color.
        //   og    → amber, exactly as before.
        /// Primary accent — cursor, active/selected glyphs, links, primary CTA fill.
        static let accent = themed(cleanLight: 0x1C1C1E, cleanDark: 0xF2F2F7, ogLight: 0xE0832F, ogDark: 0xFFB454)
        /// A brighter pop for glows and the progress-bar head.
        static let accentBright = themed(cleanLight: 0x000000, cleanDark: 0xFFFFFF, ogLight: 0xFFB454, ogDark: 0xFFB454)
        /// Pressed/highlighted state of an accent fill.
        static let accentPressed = themed(cleanLight: 0x000000, cleanDark: 0xD1D1D6, ogLight: 0xC56E1F, ogDark: 0xE0832F)
        /// Soft accent wash — selected tiles, badges, hover backings (per-variant alpha).
        static let accentSoft = UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch activeFamily {
            case .clean: return dark ? UIColor(hex: 0xF2F2F7, alpha: 0.16) : UIColor(hex: 0x1C1C1E, alpha: 0.08)
            case .og:    return dark ? UIColor(hex: 0xFFB454, alpha: 0.18) : UIColor(hex: 0xE0832F, alpha: 0.14)
            }
        }
        /// Text/glyph drawn on top of an accent fill.
        static let onAccent = themed(cleanLight: 0xFFFFFF, cleanDark: 0x1C1C1E, ogLight: 0xFFFFFF, ogDark: 0x1A140E)
        /// Deep brand mark color (used by the brand glyph; OG brown / clean near-black).
        static let brandBrown = themed(cleanLight: 0x1C1C1E, cleanDark: 0xF2F2F7, ogLight: 0x3A2417, ogDark: 0x3A2417)

        // Surfaces (layered elevation).
        /// Window background.
        static let surfaceBase = themed(cleanLight: 0xF2F2F7, cleanDark: 0x000000, ogLight: 0xF7F5F2, ogDark: 0x14110E)
        /// Elevated chrome (top bar, bottom toolbar).
        static let surfaceRaised = themed(cleanLight: 0xFFFFFF, cleanDark: 0x1C1C1E, ogLight: 0xFFFFFF, ogDark: 0x1F1A15)
        /// Omnibox pill fill.
        static let surfaceField = themed(cleanLight: 0xEEEEF0, cleanDark: 0x2C2C2E, ogLight: 0xEFEAE4, ogDark: 0x2A231C)
        /// Cards (tab cells, menu list container, install card).
        static let surfaceCard = themed(cleanLight: 0xFFFFFF, cleanDark: 0x1C1C1E, ogLight: 0xFFFFFF, ogDark: 0x241D17)
        /// Sunken backing (tab thumbnail area, NTP tiles).
        static let surfaceCardSunken = themed(cleanLight: 0xE9E9EE, cleanDark: 0x161618, ogLight: 0xF0ECE6, ogDark: 0x1A150F)
        /// Dimming scrim behind sheets / the tab grid — black at a per-variant alpha.
        static let surfaceScrim = UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch activeFamily {
            case .clean: return UIColor(hex: 0x000000, alpha: dark ? 0.55 : 0.32)
            case .og:    return UIColor(hex: 0x000000, alpha: dark ? 0.50 : 0.40)
            }
        }
        /// Tint backing for a tab card's blurred header strip.
        static let surfaceMenuHeader = themed(cleanLight: 0xFBFBFD, cleanDark: 0x2C2C2E, ogLight: 0xFBF8F4, ogDark: 0x2A231C)

        // Text.
        static let textPrimary = themed(cleanLight: 0x1C1C1E, cleanDark: 0xF5F5F7, ogLight: 0x1A140E, ogDark: 0xF5EFE7)
        static let textSecondary = themed(cleanLight: 0x6C6C70, cleanDark: 0xAEAEB2, ogLight: 0x6B6058, ogDark: 0xB6A99C)
        static let textTertiary = themed(cleanLight: 0x9A9AA0, cleanDark: 0x7C7C80, ogLight: 0x9A8E82, ogDark: 0x7E7165)

        // Icons — resting glyphs are NEUTRAL; accent is reserved for active/selected/pressed.
        static let iconPrimary = themed(cleanLight: 0x3A3A3C, cleanDark: 0xE5E5EA, ogLight: 0x4A4038, ogDark: 0xD9CFC4)
        static let iconActive = accent
        static let iconDisabled = themed(cleanLight: 0x3A3A3C, cleanDark: 0xE5E5EA,
                                         ogLight: 0x4A4038, ogDark: 0xD9CFC4, alpha: 0.4)

        // Borders & dividers.
        static let borderSubtle = themed(cleanLight: 0xE3E3E8, cleanDark: 0x2C2C2E, ogLight: 0xE2DBD2, ogDark: 0x322A22)
        static let borderStrong = themed(cleanLight: 0xD0D0D5, cleanDark: 0x3A3A3C, ogLight: 0xD2C7BB, ogDark: 0x42382E)
        static let borderSelected = accent

        // Status (shared across families — these read as themselves regardless of look).
        static let secure = UIColor(hex: 0x3DA639)     // TLS lock — green
        static let insecure = UIColor(hex: 0xC0392B)   // not secure — red
        static let warning = themed(cleanLight: 0xC2410C, cleanDark: 0xFB923C, ogLight: 0xE0832F, ogDark: 0xFFB454)
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
        static let omniboxHeight: CGFloat = 36
        static let omniboxCornerRadius: CGFloat = 12
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
