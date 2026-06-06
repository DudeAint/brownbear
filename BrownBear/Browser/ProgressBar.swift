//
//  ProgressBar.swift
//  BrownBear
//
//  The thin determinate load indicator under the omnibox, matching Chrome's behavior: it
//  animates toward the page's estimated progress and fades out smoothly on completion. The fill
//  is an amber gradient (accent → accentBright) whose leading edge stays the brightest, giving the
//  bar a soft "head" as it advances (Brave). The gradient is the fill view's *backing layer*, so
//  its geometry animates as a real view property inside `UIView.animate` — the bright head rides
//  the progress edge in lock-step instead of drifting on Core Animation's default implicit timing.
//

import UIKit

final class ProgressBar: UIView {

    /// A view whose backing layer is a `CAGradientLayer`. Because the gradient is the view's own
    /// layer (not a hosted sublayer), animating the view's frame inside a `UIView.animate` block
    /// drives the gradient with that block's duration/curve — no standalone-layer timing desync.
    private final class GradientFillView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
    }

    private let fill = GradientFillView()
    private var fillWidthFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        if let gradient = fill.layer as? CAGradientLayer {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
        }
        refreshGradientColors()
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutFill(animated: false)
    }

    /// Update the displayed progress in 0...1. Pass `animated` for in-flight updates.
    func setProgress(_ progress: Double, animated: Bool) {
        let clamped = CGFloat(max(0, min(1, progress)))
        fillWidthFraction = clamped
        layoutFill(animated: animated)
    }

    /// Show the bar (alpha 1) when a load begins.
    func show() {
        layer.removeAllAnimations()
        alpha = 1
    }

    /// Animate to full then fade out, used when a load finishes or fails.
    func complete() {
        setProgress(1, animated: true)
        UIView.animate(withDuration: BrownBearTheme.Motion.quick, delay: 0.12, options: []) {
            self.alpha = 0
        } completion: { finished in
            guard finished else { return }
            self.setProgress(0, animated: false)
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // CGColor-backed gradient stops must be rebuilt when light/dark appearance changes.
        refreshGradientColors()
    }

    // MARK: - Private

    private func refreshGradientColors() {
        guard let gradient = fill.layer as? CAGradientLayer else { return }
        // accent → accentBright: the right (leading) edge is the brightest, forming the head.
        gradient.colors = [
            BrownBearTheme.Palette.accent.cgColor,
            BrownBearTheme.Palette.accentBright.cgColor
        ]
        gradient.locations = [0, 1]
    }

    private func layoutFill(animated: Bool) {
        let width = bounds.width * fillWidthFraction
        let frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        guard animated else {
            // Force an instant update even if layoutSubviews is invoked inside an ambient
            // animation (e.g. rotation): suppress the backing layer's implicit action.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = frame
            CATransaction.commit()
            return
        }
        // fill.frame is a real view property here, so the backing gradient layer animates with the
        // block's timing — the bright head advances in lock-step with the fill edge.
        UIView.animate(withDuration: BrownBearTheme.Motion.quick,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            self.fill.frame = frame
        }
    }
}
