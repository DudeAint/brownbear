//
//  DashboardTheme.swift
//  BrownBear
//
//  SwiftUI design tokens for the dashboard + editor, bridged from the UIKit BrownBearTheme so the
//  whole app shares one amber/brown design language.
//

import SwiftUI

enum BBTheme {

    enum Color {
        static let accent = SwiftUI.Color(uiColor: BrownBearTheme.Palette.accent)
        /// The "on" fill for switches/toggles — contrasts with the white knob in dark mode (plain `accent`
        /// is near-white there, which made on-switches read white-on-white).
        static let toggleOn = SwiftUI.Color(uiColor: BrownBearTheme.Palette.toggleOn)
        static let accentBright = SwiftUI.Color(uiColor: BrownBearTheme.Palette.accentBright)
        static let background = SwiftUI.Color(uiColor: BrownBearTheme.Palette.background)
        static let chrome = SwiftUI.Color(uiColor: BrownBearTheme.Palette.chrome)
        static let card = SwiftUI.Color(uiColor: BrownBearTheme.Palette.cell)
        static let fieldFill = SwiftUI.Color(uiColor: BrownBearTheme.Palette.omniboxFill)
        static let textPrimary = SwiftUI.Color(uiColor: BrownBearTheme.Palette.textPrimary)
        static let textSecondary = SwiftUI.Color(uiColor: BrownBearTheme.Palette.textSecondary)
        static let separator = SwiftUI.Color(uiColor: BrownBearTheme.Palette.separator)
        static let secure = SwiftUI.Color(uiColor: BrownBearTheme.Palette.secure)
        static let destructive = SwiftUI.Color(uiColor: BrownBearTheme.Palette.destructive)
        static let brandBrown = SwiftUI.Color(uiColor: BrownBearTheme.Palette.brandBrown)
    }

    enum Metric {
        static let cardCorner: CGFloat = 16
        static let cardPadding: CGFloat = 14
        static let sectionSpacing: CGFloat = 16
    }

    /// The signature dashboard background — a subtle amber-tinted radial over the base.
    static var backgroundGradient: some View {
        ZStack {
            Color.background
            RadialGradient(
                colors: [Color.brandBrown.opacity(0.45), .clear],
                center: .top, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// A reusable rounded card container.
struct BBCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(BBTheme.Metric.cardPadding)
            .background(BBTheme.Color.card)
            .clipShape(RoundedRectangle(cornerRadius: BBTheme.Metric.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BBTheme.Metric.cardCorner, style: .continuous)
                    .strokeBorder(BBTheme.Color.separator, lineWidth: 0.5))
    }
}

/// A small pill label used for grants, run-at, schedules.
struct BBPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = BBTheme.Color.accent
    init(_ text: String, systemImage: String? = nil, tint: Color = BBTheme.Color.accent) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14))
        .clipShape(Capsule())
    }
}
