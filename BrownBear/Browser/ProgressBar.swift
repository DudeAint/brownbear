//
//  ProgressBar.swift
//  BrownBear
//
//  The thin determinate load indicator under the omnibox, matching Chrome's behavior: it
//  animates toward the page's estimated progress and fades out smoothly on completion.
//

import UIKit

final class ProgressBar: UIView {

    private let track = UIView()
    private let fill = UIView()
    private var fillWidthFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        track.backgroundColor = .clear
        fill.backgroundColor = BrownBearTheme.Palette.accent
        addSubview(track)
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        track.frame = bounds
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

    private func layoutFill(animated: Bool) {
        let target = CGRect(x: 0, y: 0, width: bounds.width * fillWidthFraction, height: bounds.height)
        guard animated else { fill.frame = target; return }
        UIView.animate(withDuration: BrownBearTheme.Motion.quick,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            self.fill.frame = target
        }
    }
}
