//
//  ToolbarButton.swift
//  BrownBear
//
//  The shared glyph button for the browser chrome (bottom toolbar + omnibox in-pill controls).
//  Centralizes the state→token tinting so every chrome button looks and animates the same: resting
//  glyphs are NEUTRAL (iconPrimary), accent is reserved for highlighted/selected, disabled dims.
//  Symbols are Dynamic-Type-scaled. Long-press fires a haptic + callback. (Firefox/Brave pattern.)
//

import UIKit

final class ToolbarButton: UIButton {

    /// Optional long-press action (e.g. back/forward history, new-tab options).
    var longPressHandler: (() -> Void)?

    private var symbolName: String?
    private var symbolPointSize: CGFloat = 17

    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        configuration = config
        // chevron.backward/forward are direction-aware SF Symbols (auto-mirror in RTL); no manual flip needed.
        refreshTint()
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress)))
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Re-tint on every interactive state change; the press also springs the glyph for a tactile feel.
    override var isHighlighted: Bool { didSet { refreshTint(); animatePress(isHighlighted) } }
    override var isSelected: Bool { didSet { refreshTint() } }
    override var isEnabled: Bool { didSet { refreshTint() } }

    /// A premium press feel: a quick, taut shrink on touch-down and a lightly springy settle on
    /// release. Transform-only, so it never disturbs layout or the hit area. (`beginFromCurrentState`
    /// keeps a fast double-tap from snapping.)
    private func animatePress(_ pressed: Bool) {
        UIView.animate(withDuration: pressed ? 0.10 : 0.34,
                       delay: 0,
                       usingSpringWithDamping: pressed ? 1.0 : 0.52,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = pressed ? CGAffineTransform(scaleX: 0.86, y: 0.86) : .identity
        }
    }

    /// Set the SF Symbol; no-ops if unchanged so rapid state updates don't rebuild the image.
    func setSymbol(_ name: String, pointSize: CGFloat = 17) {
        guard name != symbolName || pointSize != symbolPointSize else { return }
        symbolName = name
        symbolPointSize = pointSize
        configuration?.image = UIImage(systemName: name,
                                       withConfiguration: BrownBearTheme.Typography.symbol(pointSize: pointSize))
    }

    private func refreshTint() {
        let color: UIColor
        if !isEnabled {
            color = BrownBearTheme.Palette.iconDisabled
        } else if isHighlighted || isSelected {
            color = BrownBearTheme.Palette.iconActive
        } else {
            color = BrownBearTheme.Palette.iconPrimary
        }
        // Dynamic UIColors auto-resolve light/dark, so no manual traitCollection handling needed.
        configuration?.baseForegroundColor = color
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let longPressHandler else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        longPressHandler()
    }
}
