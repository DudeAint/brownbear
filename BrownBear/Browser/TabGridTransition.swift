//
//  TabGridTransition.swift
//  BrownBear
//
//  The custom present/dismiss animation for the tab grid — the "refined" zoom morph: the grid springs
//  up from a slightly-shrunk, transparent state on open and shrinks back out on close, so switching
//  between the page and the grid reads as one continuous surface rather than a hard modal cut. Used
//  with the standard `.fullScreen` style (UIKit still honors a transitioningDelegate's animators), so
//  view lifecycle stays stock; only the motion is ours.
//

import UIKit

/// Animates one direction of the tab-grid transition. `isPresenting` selects open vs. close.
final class TabGridTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    private let shrunk = CGAffineTransform(scaleX: 0.92, y: 0.92)

    init(presenting: Bool) {
        self.isPresenting = presenting
        super.init()
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.42 : 0.32
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        let duration = transitionDuration(using: context)

        if isPresenting {
            guard let toViewController = context.viewController(forKey: .to),
                  let gridView = context.view(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            gridView.frame = context.finalFrame(for: toViewController)
            container.addSubview(gridView)
            gridView.alpha = 0
            gridView.transform = shrunk
            UIView.animate(withDuration: duration, delay: 0,
                           usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
                           options: [.allowUserInteraction]) {
                gridView.alpha = 1
                gridView.transform = .identity
            } completion: { _ in
                gridView.transform = .identity
                context.completeTransition(!context.transitionWasCancelled)
            }
        } else {
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
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.allowUserInteraction, .curveEaseIn]) {
                gridView.alpha = 0
                gridView.transform = self.shrunk
            } completion: { _ in
                gridView.transform = .identity
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}

/// Vends the open/close animators for the tab grid. Held by the browser controller and assigned as
/// the grid's `transitioningDelegate` (UIKit keeps only a weak reference to it).
final class TabGridTransitionController: NSObject, UIViewControllerTransitioningDelegate {

    func animationController(forPresented presented: UIViewController,
                             presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        TabGridTransitionAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning? {
        TabGridTransitionAnimator(presenting: false)
    }
}
