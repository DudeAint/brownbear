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

        // The hero card sits on top, starting at the tapped card's frame and growing to fill the page.
        // Aspect-fill so the card image scales UNIFORMLY as the (differently-proportioned) frame grows —
        // it crops the overflow instead of stretching the content vertically.
        let hero = UIImageView(image: image)
        hero.contentMode = .scaleAspectFill
        let startCorner = BrownBearTheme.Metrics.cellCornerRadius
        hero.frame = heroFrame
        hero.layer.cornerRadius = startCorner
        hero.layer.cornerCurve = .continuous
        hero.clipsToBounds = true
        container.addSubview(hero)

        // Round the corners out to a square page edge. A CABasicAnimation is the reliable way to animate
        // a layer corner alongside a UIView spring (UIView.animate doesn't carry cornerRadius on springs).
        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = startCorner
        corner.toValue = 0
        corner.duration = duration
        corner.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hero.layer.cornerRadius = 0
        hero.layer.add(corner, forKey: "heroCorner")

        // The surrounding cards fall away while the hero springs out to full screen.
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2,
                       options: [.allowUserInteraction]) {
            gridView.alpha = 0
            hero.frame = pageFrame
        } completion: { _ in
            hero.removeFromSuperview()
            gridView.alpha = 1
            gridView.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        }

        // Dissolve the (now full-screen) card snapshot into the live page over the back half, so a page
        // that no longer matches its snapshot cross-fades in rather than popping.
        UIView.animate(withDuration: duration * 0.4, delay: duration * 0.55,
                       options: [.curveEaseIn]) {
            hero.alpha = 0
        }
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
        selectedCardImage = nil
        selectedCardFrame = .zero
        return animator
    }
}
