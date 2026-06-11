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

    /// Minimum deliberate top-overscroll (points) during a drag for a pull-to-refresh to count. Filters
    /// momentum bounces; a real downward pull goes well past this before UIRefreshControl even fires.
    private static var pullRefreshMinOverscroll: CGFloat { 40 }

    /// A new drag starts — reset the pull-to-refresh overscroll tracker for this gesture.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === tabManager.activeTab?.webView.scrollView else { return }
        pullMaxOverscroll = 0
    }

    /// True only when the just-ended drag pulled deliberately past the top — the pull-to-refresh gate.
    func tabShouldAcceptPullToRefresh(_ tab: Tab) -> Bool {
        pullMaxOverscroll >= Self.pullRefreshMinOverscroll
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only the active tab's web view drives the chrome; ignore any stale delegate callbacks.
        guard scrollView === tabManager.activeTab?.webView.scrollView else { return }
        // Track the drag's deepest top-overscroll so pull-to-refresh fires only on a deliberate pull.
        if scrollView.isDragging {
            let overscroll = -scrollView.adjustedContentInset.top - scrollView.contentOffset.y
            if overscroll > pullMaxOverscroll { pullMaxOverscroll = overscroll }
        }
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

        // Not worth collapsing for a page barely taller than the bar(s) that would hide.
        guard scrollView.contentSize.height > scrollView.bounds.height + chromeHideDistance else {
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
            applyCollapsedStripInset(reveal: false)   // top mode never overlays the page bottom
            animateChrome(animated) {
                self.omnibox.alpha = hidden ? 0 : 1   // clipped omnibox fades as the bar rolls away
                self.collapsedBottomBar.alpha = 0     // the collapsed domain strip is a bottom-mode affordance
                self.view.layoutIfNeeded()
            }
        case .bottom:
            guard let bottomConstraint = bottomChromeBottomConstraint else { return }
            // While editing, the bar is lifted above the keyboard — never fight that (a stray
            // showChrome / new-page load mid-edit must not drop the omnibox behind the keyboard).
            // Otherwise slide the omnibox + toolbar fully below the screen (bar + toolbar + inset).
            bottomConstraint.constant = keyboardVisible ? -keyboardLiftOverlap : (hidden ? chromeHideDistance : 0)
            let revealStrip = hidden && !keyboardVisible
            // Inset the page so its bottom rows scroll clear of the collapsed strip overlaying them.
            applyCollapsedStripInset(reveal: revealStrip)
            // Seed a small upward offset so the lock + domain TRAVEL DOWN into place with the collapsing
            // bar, rather than just popping in. The animation below settles them to rest (.identity).
            if revealStrip { collapsedHostStack.transform = CGAffineTransform(translationX: 0, y: -10) }
            animateChrome(animated) {
                // Fade the Safari-style collapsed domain strip in as the bar slides away (never while
                // editing), sliding the lock + domain down to their resting spot.
                self.collapsedBottomBar.alpha = revealStrip ? 1 : 0
                self.collapsedHostStack.transform = revealStrip ? .identity : CGAffineTransform(translationX: 0, y: -10)
                self.view.layoutIfNeeded()
            }
        }
    }

    /// The chrome-coloured collapsed domain strip's band height above the safe area (matches the
    /// `collapsedBottomBar` top inset in +Layout). With the safe-area bottom it is the page region the
    /// strip overlays when the bottom bar is hidden.
    private static let collapsedStripBand: CGFloat = 36

    /// Give the active page a bottom content inset matching the collapsed strip (when it's revealed) so
    /// the last rows can scroll above it instead of hiding behind it; clear it when the strip is gone.
    private func applyCollapsedStripInset(reveal: Bool) {
        guard let scrollView = tabManager.activeTab?.webView.scrollView else { return }
        let cover: CGFloat = reveal ? (Self.collapsedStripBand + view.safeAreaInsets.bottom) : 0
        guard scrollView.contentInset.bottom != cover else { return }
        scrollView.contentInset.bottom = cover
        scrollView.verticalScrollIndicatorInsets.bottom = cover
    }

    /// Tap on the collapsed bottom strip → bring the full bottom bar back (Safari behavior).
    @objc func expandBottomBarFromCollapsed() { showChrome(animated: true) }

    /// How far the chrome travels when hidden in the current position: the top bar's collapsible height,
    /// or the full bottom chrome (omnibox + toolbar + home-indicator inset). Also the minimum extra page
    /// height worth collapsing for.
    var chromeHideDistance: CGFloat {
        switch AppSettings.addressBarPosition {
        case .top: return omniboxBarHeight
        case .bottom: return omniboxBarHeight + BrownBearTheme.Metrics.toolbarHeight + view.safeAreaInsets.bottom
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
        // A presented surface (e.g. the dashboard's "Browse the stores" rows) asked to open a URL: dismiss
        // it, then load the URL in a new tab.
        openURLObserver = NotificationCenter.default.addObserver(
            forName: .brownBearOpenURL, object: nil, queue: .main) { [weak self] note in
            guard let self, let url = note.userInfo?["url"] as? URL else { return }
            let open = { self.handleExternalURL(url) }
            if self.presentedViewController != nil {
                self.dismiss(animated: true, completion: open)
            } else {
                open()
            }
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
        keyboardLiftOverlap = overlap   // remembered so a re-layout preserves the lift
        // Editing only happens with the bar shown (it's tappable only when shown), so on retract the bar
        // returns fully shown — keep chromeHidden in sync so scroll-hide resumes from the right state.
        if overlap == 0 { chromeHidden = false }
        // Negative constant lifts the toolbar.bottom (and the omnibox above it) up over the keyboard.
        bottomConstraint.constant = overlap > 0 ? -overlap : 0
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) { self.view.layoutIfNeeded() }
    }
}
