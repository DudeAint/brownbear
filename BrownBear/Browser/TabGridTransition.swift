//
//  TabGridTransition.swift
//  BrownBear
//
//  The custom present/dismiss animation for the tab grid. Two motions:
//
//  • Open  — the grid springs up from a slightly-shrunk, transparent state, so summoning the grid reads
//    as one continuous surface rather than a hard modal cut.
//  • Enter — when you TAP a card, that card expands into the full page (the Safari/Arc "open from card"
//    morph): a snapshot of the tapped card grows from its grid position to fill the screen while the
//    surrounding cards fall away, then dissolves into the now-live page. A plain Done / new-tab dismiss
//    (no card) keeps the soft fade-shrink fallback.
//
//  Used with the standard `.fullScreen` style (UIKit still honors a transitioningDelegate's animators),
//  so view lifecycle stays stock; only the motion is ours.
//

import UIKit

/// Animates one direction of the tab-grid transition. `isPresenting` selects open vs. close; on close,
/// a non-nil `heroImage` switches the soft fade for the expand-from-card morph.
final class TabGridTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    private let shrunk = CGAffineTransform(scaleX: 0.92, y: 0.92)

    /// Set by the controller when dismissing because the user selected a card: an IMAGE of that card and
    /// its on-screen frame (window coordinates), so the dismiss expands exactly that card. An image (not a
    /// snapshot VIEW) so it can scale with aspect-fill — the card and the page have different aspect ratios,
    /// and stretching a snapshot view's frame between them squashes/stretches the content vertically.
    var heroImage: UIImage?
    var heroFrame: CGRect = .zero
    /// Where the hero should END (window coords): the page's CONTENT area (the web view's frame), not the
    /// whole screen. The hero IS the page's content-area snapshot, so growing it to the content frame keeps
    /// it 1:1 with the live page underneath — the dissolve is seamless instead of an instant zoom-out.
    /// `.zero` falls back to the full screen.
    var heroTargetFrame: CGRect = .zero

    init(presenting: Bool) {
        self.isPresenting = presenting
        super.init()
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        if isPresenting { return 0.42 }
        return heroImage != nil ? 0.40 : 0.32
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresent(using: context)
        } else if let image = heroImage, heroFrame != .zero {
            animateHeroExpand(image, using: context)
        } else {
            animateDismissFade(using: context)
        }
    }

    // MARK: - Open the grid

    private func animatePresent(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toViewController = context.viewController(forKey: .to),
              let gridView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        gridView.frame = context.finalFrame(for: toViewController)
        container.addSubview(gridView)
        gridView.alpha = 0
        gridView.transform = shrunk
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
                       options: [.allowUserInteraction]) {
            gridView.alpha = 1
            gridView.transform = .identity
        } completion: { _ in
            gridView.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    // MARK: - Enter a tab (expand the selected card into the page)

    private func animateHeroExpand(_ image: UIImage, using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let gridView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
        }
        let duration = transitionDuration(using: context)

        // Reveal the already-installed page beneath the grid so the expanding card lands on the real page.
        var pageFrame = container.bounds
        if let toViewController = context.viewController(forKey: .to),
           let browserView = context.view(forKey: .to) {
            pageFrame = context.finalFrame(for: toViewController)
            browserView.frame = pageFrame
            container.insertSubview(browserView, belowSubview: gridView)
        }
        let finalFrame = heroTargetFrame == .zero ? pageFrame : heroTargetFrame

        // The hero is the page's own snapshot. It grows from the tapped card's picture to the content-area
        // frame (not the whole screen) so it sits 1:1 on the live page beneath — same scale, seamless dissolve.
        //
        // It's TOP-anchored: a clip view animates card→page, and the page image inside is pinned to the top
        // and sized to the page's true aspect. So the page's TOP edge stays put the whole way (the Safari
        // morph), matching both the top-anchored tab card it grows FROM and the top-anchored live page it
        // dissolves INTO. A single centre-gravity aspect-fill instead drifts the content vertically and — if
        // the snapshot's aspect no longer matches the live page — leaves the hero reading too tall/high at
        // the end. The clip can never exceed `finalFrame`, so the hero is never taller than the live page.
        let startCorner = BrownBearTheme.Metrics.cellCornerRadius
        let pageAspect = image.size.width / max(image.size.height, 1)
        let heroClip = UIView(frame: heroFrame)
        heroClip.clipsToBounds = true
        heroClip.layer.cornerRadius = startCorner
        heroClip.layer.cornerCurve = .continuous

        let pageView = UIImageView(image: image)
        pageView.contentMode = .scaleToFill   // sized to the exact page aspect → fills width, no distortion
        pageView.frame = topAnchoredPageFrame(width: heroFrame.width, aspect: pageAspect)
        heroClip.addSubview(pageView)
        container.addSubview(heroClip)

        // Round the corners out to a square page edge. A CABasicAnimation is the reliable way to animate
        // a layer corner alongside a UIView animation (UIView.animate doesn't always carry cornerRadius).
        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = startCorner
        corner.toValue = 0
        corner.duration = duration
        corner.timingFunction = CAMediaTimingFunction(name: .easeOut)
        heroClip.layer.cornerRadius = 0
        heroClip.layer.add(corner, forKey: "heroCorner")

        // A smooth decelerate (damping 1.0 = no overshoot/bounce, which reads as gentler than a spring).
        // The clip and its top-pinned page grow in lockstep; the surrounding cards fall away.
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: 1.0, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .curveEaseInOut]) {
            gridView.alpha = 0
            heroClip.frame = finalFrame
            pageView.frame = self.topAnchoredPageFrame(width: finalFrame.width, aspect: pageAspect)
        } completion: { _ in
            heroClip.removeFromSuperview()
            gridView.alpha = 1
            gridView.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        }

        // Dissolve the snapshot into the live page over the back half, so a page that no longer matches its
        // snapshot cross-fades in rather than popping.
        UIView.animate(withDuration: duration * 0.45, delay: duration * 0.5,
                       options: [.curveEaseInOut]) {
            heroClip.alpha = 0
        }
    }

    /// A page image's frame inside its clip: full width, top-pinned (y = 0), height set by the page's own
    /// aspect. Wider than the clip vertically → the bottom is clipped; the visible top region stays 1:1 with
    /// the live page. Linear interpolation of this frame keeps width == clip width and the aspect exact.
    private func topAnchoredPageFrame(width: CGFloat, aspect: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: width, height: aspect > 0 ? width / aspect : width)
    }

    // MARK: - Plain dismiss (Done / new tab)

    private func animateDismissFade(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let gridView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
        }
        // Re-insert the browser below the grid so it's revealed as the grid shrinks away.
        if let toViewController = context.viewController(forKey: .to),
           let browserView = context.view(forKey: .to) {
            browserView.frame = context.finalFrame(for: toViewController)
            container.insertSubview(browserView, belowSubview: gridView)
        }
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0,
                       options: [.allowUserInteraction, .curveEaseIn]) {
            gridView.alpha = 0
            gridView.transform = self.shrunk
        } completion: { _ in
            gridView.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}

/// Vends the open/close animators for the tab grid. Held by the browser controller and assigned as
/// the grid's `transitioningDelegate` (UIKit keeps only a weak reference to it).
final class TabGridTransitionController: NSObject, UIViewControllerTransitioningDelegate {

    /// Set by the browser immediately before a *select* dismiss, so the dismiss animator expands the
    /// tapped card into the page. Consumed (cleared) when the dismiss animator is vended, so a later
    /// Done/back dismiss falls back to the soft fade.
    var selectedCardImage: UIImage?
    var selectedCardFrame: CGRect = .zero
    /// The page's content-area frame (window coords) the hero should grow to — so the content snapshot
    /// lands 1:1 on the live page rather than over-zoomed. `.zero` → full screen.
    var selectedContentFrame: CGRect = .zero

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        TabGridTransitionAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning? {
        let animator = TabGridTransitionAnimator(presenting: false)
        animator.heroImage = selectedCardImage
        animator.heroFrame = selectedCardFrame
        animator.heroTargetFrame = selectedContentFrame
        selectedCardImage = nil
        selectedCardFrame = .zero
        selectedContentFrame = .zero
        return animator
    }
}
