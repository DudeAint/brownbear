//
//  GlassBackground.swift
//  BrownBear
//
//  A frosted, lightly white-tinted "glass" backdrop for floating popovers (Site Shields, and the
//  extension popup to come) so the page stays faintly visible behind them — instead of a flat opaque
//  fill. Adapts to light/dark via a system material; a whisper of white frost reads as "tinted white
//  glass" in light mode and is near-nil in dark. Reusable so every popover shares one look.
//

import UIKit

enum GlassBackground {

    /// Install the glass behind `view`'s content: clears the view's own fill and inserts a full-bleed
    /// blur (+ subtle white tint) at the back. Content added to `view` afterwards sits above the glass.
    /// Returns the effect view in case the caller wants to tune it.
    @discardableResult
    static func install(in view: UIView, cornerRadius: CGFloat = 0) -> UIVisualEffectView {
        view.backgroundColor = .clear

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        if cornerRadius > 0 {
            blur.layer.cornerRadius = cornerRadius
            blur.layer.cornerCurve = .continuous
            blur.clipsToBounds = true
        }
        view.insertSubview(blur, at: 0)

        // A faint white frost so the glass reads as "tinted white" in light mode (and barely anything in
        // dark, where the material is already a dark glass). Non-interactive so taps pass to the content.
        let tint = UIView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.backgroundColor = UIColor(dynamicLight: UIColor.white.withAlphaComponent(0.18),
                                       dark: UIColor.white.withAlphaComponent(0.04))
        tint.isUserInteractionEnabled = false
        blur.contentView.addSubview(tint)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tint.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            tint.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor)
        ])
        return blur
    }
}
