//
//  BrownBearBrowserViewController+ScrollChrome.swift
//  BrownBear
//
//  Hide-the-bar-on-scroll + the chrome-layout observers, for both address-bar positions:
//   • Top: collapse the bar's HEIGHT to the safe-area strip (omnibox clipped + faded); the status-bar /
//     Dynamic Island region keeps its chrome backing and the page never slides under it.
//   • Bottom: slide the whole bottom chrome (omnibox + toolbar) down off-screen together.
//  Both honour AppSettings.hideBarsOnScroll (default on). Also keeps the BOTTOM bar above the keyboard
//  while editing (the omnibox would otherwise sit behind it), and re-lays-out live when the address-bar
//  position preference changes.
//

import UIKit

extension BrownBearBrowserViewController: UIScrollViewDelegate {

    /// How many points of per-frame scroll movement to ignore as noise before reacting to a direction.
    private static var scrollDeadzone: CGFloat { 0.5 }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only the active tab's web view drives the chrome; ignore any stale delegate callbacks.
        guard scrollView === tabManager.activeTab?.webView.scrollView else { return }
        // Don't fight the keyboard-lift while editing the bottom bar.
        guard !keyboardVisible else { return }

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
        guard scrollView.contentSize.height > scrollView.bounds.height + omniboxBarHeight else {
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

    /// Hide or show the chrome — collapse the top bar's height (top mode) or slide the bottom chrome
    /// down (bottom mode). The progress bar + content area, pinned to the moving edge, follow and the
    /// page grows to fill.
    func applyChromeHidden(_ hidden: Bool, animated: Bool) {
        switch AppSettings.addressBarPosition {
        case .top:
            guard let heightConstraint = topChromeHeightConstraint else { return }
            heightConstraint.constant = hidden ? view.safeAreaInsets.top
                                               : view.safeAreaInsets.top + omniboxBarHeight
            animateChrome(animated) {
                self.omnibox.alpha = hidden ? 0 : 1   // clipped omnibox fades as the bar rolls away
                self.view.layoutIfNeeded()
            }
        case .bottom:
            guard let bottomConstraint = bottomChromeBottomConstraint else { return }
            // Slide the omnibox + toolbar fully below the screen (bar + toolbar + home-indicator inset).
            let distance = omniboxBarHeight + BrownBearTheme.Metrics.toolbarHeight + view.safeAreaInsets.bottom
            bottomConstraint.constant = hidden ? distance : 0
            animateChrome(animated) { self.view.layoutIfNeeded() }
        }
    }

    private func animateChrome(_ animated: Bool, _ apply: @escaping () -> Void) {
        guard animated else { apply(); return }
        // A quick, lightly-damped spring — snappy on the way out, still refined rather than abrupt.
        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.6,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    }

    // MARK: - Layout observers (live position switch + keyboard avoidance)

    /// Register for the address-bar-position preference change and for keyboard-frame changes.
    func registerChromeLayoutObservers() {
        chromeLayoutObserver = NotificationCenter.default.addObserver(
            forName: .brownBearChromeLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.applyAddressBarPosition(AppSettings.addressBarPosition, animated: true)
        }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.handleKeyboardFrameChange(note)
        }
    }

    /// Lift the BOTTOM chrome above the keyboard while editing (so the omnibox isn't behind it). No-op in
    /// top mode (the keyboard covering the bottom toolbar there is fine — the user looks at the top bar).
    private func handleKeyboardFrameChange(_ note: Notification) {
        guard AppSettings.addressBarPosition == .bottom,
              let bottomConstraint = bottomChromeBottomConstraint,
              let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let keyboardCover = view.bounds.height - view.convert(endFrame, from: nil).origin.y
        let overlap = max(0, keyboardCover - view.safeAreaInsets.bottom)   // keyboard height above the safe area
        keyboardVisible = overlap > 0
        // Negative constant lifts the toolbar.bottom (and the omnibox above it) up over the keyboard.
        bottomConstraint.constant = overlap > 0 ? -overlap : 0
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) { self.view.layoutIfNeeded() }
    }
}
