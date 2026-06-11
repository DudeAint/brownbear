//
//  ThemeController.swift
//  BrownBear
//
//  Applies `AppSettings.theme` to the live UI. The design tokens in `BrownBearTheme` resolve by
//  (family × light/dark): the light/dark axis comes from the trait environment, but the family
//  (clean vs OG) is a global the dynamic-color providers read at resolve time. UIKit only re-runs a
//  dynamic-color provider when the trait collection's light/dark actually CHANGES, so a family switch
//  at the same appearance (System ⇄ OG BrownBear) wouldn't otherwise repaint. This controller forces a
//  real trait change so EVERY dynamic color and cgColor re-resolves, and hides the one intermediate
//  frame under a snapshot cross-fade — giving a smooth, complete theme switch. SwiftUI surfaces observe
//  `ThemeStore` instead (UIKit trait changes don't, by themselves, re-render a presented SwiftUI tree).
//

import UIKit
import Combine

/// Observed by the SwiftUI dashboard/settings so they re-render when the theme changes (a family swap
/// at the same light/dark doesn't move SwiftUI's `colorScheme`, so it needs an explicit nudge).
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var theme: AppTheme = AppSettings.theme
    private init() {}
}

@MainActor
enum ThemeController {

    /// The window interface style for a theme: forced for Light/Dark, OS-driven (unspecified) for
    /// System and OG BrownBear (both follow the device light/dark). Pure — `nonisolated` so it's
    /// callable/testable off the main actor.
    nonisolated static func interfaceStyle(for theme: AppTheme) -> UIUserInterfaceStyle {
        switch theme {
        case .light: return .light
        case .dark: return .dark
        case .system, .ogBrown: return .unspecified
        }
    }

    /// Set the initial window appearance at launch (no animation). Call after `makeKeyAndVisible`.
    static func applyAtLaunch(to window: UIWindow) {
        window.overrideUserInterfaceStyle = interfaceStyle(for: AppSettings.theme)
        window.tintColor = BrownBearTheme.Palette.accent
        ThemeStore.shared.theme = AppSettings.theme
    }

    /// Apply the current `AppSettings.theme` to the live UI, cross-fading the change.
    static func apply(animated: Bool = true) {
        ThemeStore.shared.theme = AppSettings.theme
        guard let window = keyWindow else { return }
        let target = interfaceStyle(for: AppSettings.theme)

        guard animated, let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            commit(window, target: target)
            return
        }
        snapshot.frame = window.bounds
        window.addSubview(snapshot)

        // Force a genuine trait change so every dynamic color + cgColor re-resolves to the NEW family,
        // even when the light/dark didn't change (System ⇄ OG). We flip to the OPPOSITE of the target's
        // concrete style this runloop (hidden under the snapshot), then settle on the target next
        // runloop — opposite → target is always a real change, which re-runs every provider.
        let targetConcrete: UIUserInterfaceStyle = (target == .unspecified)
            ? window.traitCollection.userInterfaceStyle : target
        window.overrideUserInterfaceStyle = (targetConcrete == .dark) ? .light : .dark

        DispatchQueue.main.async {
            commit(window, target: target)
            UIView.animate(withDuration: BrownBearTheme.Motion.standard,
                           delay: 0, options: [.allowUserInteraction],
                           animations: { snapshot.alpha = 0 },
                           completion: { _ in snapshot.removeFromSuperview() })
        }
    }

    private static func commit(_ window: UIWindow, target: UIUserInterfaceStyle) {
        window.overrideUserInterfaceStyle = target
        window.tintColor = BrownBearTheme.Palette.accent
        NotificationCenter.default.post(name: .brownBearThemeChanged, object: nil)
    }

    /// The foreground key window (falls back to any connected window so launch wiring still works).
    static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return foreground?.windows.first { $0.isKeyWindow } ?? foreground?.windows.first
    }
}
