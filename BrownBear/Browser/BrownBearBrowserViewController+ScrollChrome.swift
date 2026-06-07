//
//  BrownBearBrowserViewController+ScrollChrome.swift
//  BrownBear
//
//  Hide-the-bar-on-scroll: as the user scrolls a page down, the top omnibox bar slides off the top of
//  the screen and the web content expands to fill it; scrolling up (or starting a new page load, or
//  switching tabs) brings it back. The Safari/Chrome immersive-reading behaviour, gated by the
//  AppSettings.hideBarsOnScroll preference (default on).
//
//  We drive topChromeTopConstraint.constant (owned by +Layout) and animate layout — because the
//  omnibox is pinned inside topChrome, and the progress bar + content container are pinned below it,
//  the single constant cleanly slides the bar away and grows the page area in one animation.
//

import UIKit

extension BrownBearBrowserViewController: UIScrollViewDelegate {

    /// How many points of per-frame scroll movement to ignore as noise before reacting to a direction.
    private static var scrollDeadzone: CGFloat { 0.5 }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only the active tab's web view drives the chrome; ignore any stale delegate callbacks.
        guard scrollView === tabManager.activeTab?.webView.scrollView else { return }

        guard AppSettings.hideBarsOnScroll else {
            if chromeHidden { showChrome(animated: true) }   // preference turned off → restore the bar
            return
        }

        // Only react to user-driven scrolling, not programmatic offset changes or inset settling.
        guard scrollView.isDragging || scrollView.isDecelerating else { return }

        let offsetY = scrollView.contentOffset.y
        let minOffset = -scrollView.adjustedContentInset.top
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom

        // Always reveal at the very top; ignore rubber-band overscroll past the bottom.
        if offsetY <= minOffset + 1 {
            if chromeHidden { showChrome(animated: true) }
            lastScrollOffsetY = offsetY
            return
        }
        if offsetY >= maxOffset - 1 {
            lastScrollOffsetY = offsetY
            return
        }

        // Not worth collapsing for a page barely taller than the viewport.
        guard scrollView.contentSize.height > scrollView.bounds.height + topChrome.bounds.height else {
            lastScrollOffsetY = offsetY
            return
        }

        let delta = offsetY - lastScrollOffsetY
        lastScrollOffsetY = offsetY
        if abs(delta) < Self.scrollDeadzone { return }

        if delta > 0 {
            // Scrolling down — hide as soon as you've left the very top (snappy, no dead band). The
            // "at the top → show" check above keeps a small bounce zone from collapsing the bar.
            if !chromeHidden, offsetY > minOffset + 2 {
                chromeHidden = true
                applyChromeHidden(true, animated: true)
            }
        } else if chromeHidden {
            // Scrolling up — bring it back immediately.
            chromeHidden = false
            applyChromeHidden(false, animated: true)
        }
    }

    /// Force the chrome visible and reset the scroll baseline (new page load, tab switch, top of page).
    func showChrome(animated: Bool) {
        chromeHidden = false
        lastScrollOffsetY = tabManager.activeTab?.webView.scrollView.contentOffset.y ?? 0
        applyChromeHidden(false, animated: animated)
    }

    /// Slide the top chrome off the top (hidden) or back to rest (shown) by driving its top constraint.
    /// Hidden slides up by the bar's full height so the page fills the freed space (the status bar then
    /// overlays the page, as in Safari/Chrome). Shown restores constant 0 — the unchanged resting layout.
    func applyChromeHidden(_ hidden: Bool, animated: Bool) {
        guard let topConstraint = topChromeTopConstraint else { return }
        topConstraint.constant = hidden ? -topChrome.bounds.height : 0
        let apply = { self.view.layoutIfNeeded() }
        if animated {
            // A quick, lightly-damped spring — snappy on the way out, still refined rather than abrupt.
            UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.6,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { apply() }
        } else {
            apply()
        }
    }
}
