//
//  BrownBearBrowserViewController+TabSwipe.swift
//  BrownBear
//
//  Safari-style "swipe the address bar to change tabs". A horizontal pan on the omnibox bar interactively
//  slides the current tab off and the ADJACENT tab in — and, exactly like iOS, the ADDRESS BAR moves with
//  the tab: the current URL pill slides out while the neighbour's slides in, in lockstep with the content.
//  Each tab's already-captured snapshot is used so the neighbour appears instantly "preloaded" — no flash,
//  no wait. Past a distance/velocity threshold the gesture commits to the neighbour; short of it, both the
//  content and the bar spring back, and an edge tab rubber-bands rather than dragging into empty space.
//
//  Why the bar and not the page: WKWebView owns its own interactive back/forward edge-swipe; driving tab
//  switching from the page would fight it. Anchoring the gesture to the address bar (exactly what the user
//  reaches for) keeps the two completely separate. The pan never cancels touches, so tapping the bar to
//  edit the URL still works; it only begins on a clearly-horizontal drag while not editing.
//
//  The neighbour set is the active tab's OWN privacy set (normal vs private), matching the tab grid. The
//  live web-view swap happens through the normal TabManager.setActiveTab path once the slide settles; the
//  snapshot overlays (content + bar) cover the swap, then fade.
//

import UIKit

/// Transient state for one in-flight address-bar swipe. Lives only between `.began` and the settle
/// animation's completion; `BrownBearBrowserViewController.tabSwipeSession` is nil whenever idle.
final class TabSwipeSession {
    /// The content overlay holding the three side-by-side layers (previous | current | next).
    let contentHolder: UIView
    /// The address-bar overlay holding the matching three bar layers; translated in lockstep with content.
    let barHolder: UIView
    /// The content width one tab occupies — the full commit translation and rubber-band reference.
    let width: CGFloat
    /// The tab revealed by a rightward swipe (the one before the active tab), or nil at the left edge.
    let leftTab: Tab?
    /// The tab revealed by a leftward swipe (the one after the active tab), or nil at the right edge.
    let rightTab: Tab?

    init(contentHolder: UIView, barHolder: UIView, width: CGFloat, leftTab: Tab?, rightTab: Tab?) {
        self.contentHolder = contentHolder
        self.barHolder = barHolder
        self.width = width
        self.leftTab = leftTab
        self.rightTab = rightTab
    }
}

extension BrownBearBrowserViewController: UIGestureRecognizerDelegate {

    /// Attach the pan to the address bar. Called once from viewDidLoad after the chrome is built.
    func installTabSwipeGesture() {
        tabSwipePan.addTarget(self, action: #selector(handleTabSwipePan(_:)))
        tabSwipePan.delegate = self
        tabSwipePan.cancelsTouchesInView = false   // taps to edit the URL still reach the omnibox
        tabSwipePan.delaysTouchesBegan = false
        tabSwipePan.maximumNumberOfTouches = 1
        topChrome.addGestureRecognizer(tabSwipePan)
    }

    // MARK: - Gesture delegate

    /// Begin only on a clearly-horizontal drag, while not editing the URL, and only when the active tab
    /// has a same-privacy neighbour to move to.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === tabSwipePan else { return true }
        guard tabSwipeSession == nil, !omnibox.isEditingURL else { return false }
        guard let neighbours = tabSwipeNeighbours(), neighbours.set.count > 1 else { return false }
        let velocity = tabSwipePan.velocity(in: topChrome)
        return abs(velocity.x) > abs(velocity.y)
    }

    /// Coexist with the bar's other recognizers (and the omnibox's own controls) rather than blocking them.
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === tabSwipePan
    }

    // MARK: - Pan handling

    @objc func handleTabSwipePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            beginTabSwipe()
        case .changed:
            updateTabSwipe(translationX: pan.translation(in: contentContainer).x)
        case .ended, .cancelled, .failed:
            finishTabSwipe(translationX: pan.translation(in: contentContainer).x,
                           velocityX: pan.velocity(in: contentContainer).x)
        default:
            break
        }
    }

    // MARK: - Phases

    private func beginTabSwipe() {
        guard tabSwipeSession == nil, let neighbours = tabSwipeNeighbours() else { return }
        let bounds = contentContainer.bounds
        let width = bounds.width
        guard width > 0 else { return }

        let index = neighbours.index
        let set = neighbours.set
        let leftTab = index > 0 ? set[index - 1] : nil
        let rightTab = index < set.count - 1 ? set[index + 1] : nil

        // Content overlay: previous | current | next, current centred.
        let contentHolder = UIView(frame: bounds)
        contentHolder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentHolder.clipsToBounds = true
        contentHolder.isUserInteractionEnabled = false
        contentHolder.backgroundColor = BrownBearTheme.Palette.background
        let centre = contentContainer.snapshotView(afterScreenUpdates: false) ?? UIView(frame: bounds)
        centre.frame = bounds
        contentHolder.addSubview(centre)
        contentHolder.addSubview(tabSwipeContentLayer(for: leftTab, frame: bounds.offsetBy(dx: -width, dy: 0)))
        contentHolder.addSubview(tabSwipeContentLayer(for: rightTab, frame: bounds.offsetBy(dx: width, dy: 0)))
        contentContainer.addSubview(contentHolder)

        // Address-bar overlay: the same three positions, so the bar slides with the tab (iOS behaviour).
        let barBounds = topChrome.bounds
        let barHolder = UIView(frame: barBounds)
        barHolder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        barHolder.clipsToBounds = true
        barHolder.isUserInteractionEnabled = false
        let barCentre = topChrome.snapshotView(afterScreenUpdates: false) ?? UIView(frame: barBounds)
        barCentre.frame = barBounds
        barHolder.addSubview(barCentre)
        barHolder.addSubview(tabSwipeBarLayer(for: leftTab, frame: barBounds.offsetBy(dx: -width, dy: 0)))
        barHolder.addSubview(tabSwipeBarLayer(for: rightTab, frame: barBounds.offsetBy(dx: width, dy: 0)))
        topChrome.addSubview(barHolder)

        tabSwipeSession = TabSwipeSession(contentHolder: contentHolder, barHolder: barHolder,
                                          width: width, leftTab: leftTab, rightTab: rightTab)
    }

    private func updateTabSwipe(translationX: CGFloat) {
        guard let session = tabSwipeSession else { return }
        let dx = effectiveTranslation(translationX, session: session)
        let transform = CGAffineTransform(translationX: dx, y: 0)
        session.contentHolder.transform = transform
        session.barHolder.transform = transform
    }

    private func finishTabSwipe(translationX: CGFloat, velocityX: CGFloat) {
        guard let session = tabSwipeSession else { return }
        let width = session.width
        let distanceThreshold = width * 0.32
        let flingThreshold: CGFloat = 700

        // Swipe RIGHT (positive) reveals the previous (left) tab; swipe LEFT reveals the next (right) tab.
        var target: Tab?
        var settle: CGFloat = 0
        if (translationX > distanceThreshold || velocityX > flingThreshold), let left = session.leftTab {
            target = left
            settle = width
        } else if (translationX < -distanceThreshold || velocityX < -flingThreshold), let right = session.rightTab {
            target = right
            settle = -width
        }

        guard let target else {
            // No commit: spring content and bar back to centre together, then tear the overlays down.
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                session.contentHolder.transform = .identity
                session.barHolder.transform = .identity
            } completion: { [weak self] _ in
                session.contentHolder.removeFromSuperview()
                session.barHolder.removeFromSuperview()
                self?.clearTabSwipeSession(session)
            }
            return
        }

        let settleTransform = CGAffineTransform(translationX: settle, y: 0)
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            session.contentHolder.transform = settleTransform
            session.barHolder.transform = settleTransform
        } completion: { [weak self] _ in
            guard let self else { return }
            // Swap in the neighbour's LIVE web view (and refresh the real omnibox to its URL) behind the
            // now-full-screen snapshots, then fade the overlays out to reveal them — no flash.
            self.tabManager.setActiveTab(target)
            self.contentContainer.bringSubviewToFront(session.contentHolder)
            self.topChrome.bringSubviewToFront(session.barHolder)
            UIView.animate(withDuration: 0.18) {
                session.contentHolder.alpha = 0
                session.barHolder.alpha = 0
            } completion: { _ in
                session.contentHolder.removeFromSuperview()
                session.barHolder.removeFromSuperview()
            }
            self.clearTabSwipeSession(session)
        }
    }

    // MARK: - Helpers

    /// The active tab's same-privacy set and the active tab's index within it.
    private func tabSwipeNeighbours() -> (set: [Tab], index: Int)? {
        guard let active = tabManager.activeTab else { return nil }
        let set = active.isPrivate ? tabManager.privateTabs : tabManager.normalTabs
        guard let index = set.firstIndex(where: { $0.id == active.id }) else { return nil }
        return (set, index)
    }

    /// One content slide layer for a neighbour tab: its snapshot if it has one, else a plain themed panel.
    private func tabSwipeContentLayer(for tab: Tab?, frame: CGRect) -> UIView {
        let layer = UIView(frame: frame)
        layer.backgroundColor = BrownBearTheme.Palette.background
        layer.clipsToBounds = true
        if let image = tab?.snapshot {
            let imageView = UIImageView(frame: layer.bounds)
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.image = image
            layer.addSubview(imageView)
        }
        return layer
    }

    /// One address-bar slide layer for a neighbour tab: the chrome background plus a pill at the omnibox's
    /// position showing that tab's host, so the bar reads as "this neighbour's address bar" sliding in.
    private func tabSwipeBarLayer(for tab: Tab?, frame: CGRect) -> UIView {
        let bar = UIView(frame: frame)
        bar.backgroundColor = topChrome.backgroundColor ?? BrownBearTheme.Palette.chrome
        bar.clipsToBounds = true

        let pill = UIView(frame: omnibox.frame)
        pill.backgroundColor = BrownBearTheme.Palette.surfaceField
        pill.layer.cornerRadius = BrownBearTheme.Metrics.omniboxCornerRadius
        pill.layer.cornerCurve = .continuous

        let label = UILabel(frame: pill.bounds.insetBy(dx: BrownBearTheme.Space.m, dy: 0))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        label.font = BrownBearTheme.Typography.omniboxScaled()
        label.textColor = BrownBearTheme.Palette.textPrimary
        label.lineBreakMode = .byTruncatingTail
        if let tab {
            label.text = tab.state.displayHost ?? tab.state.url?.absoluteString ?? "New Tab"
        }
        pill.addSubview(label)
        bar.addSubview(pill)
        return bar
    }

    /// The pan translation to apply, resisted (rubber-banded) when there is no tab to reveal in that
    /// direction so an edge tab can't be dragged into empty space.
    private func effectiveTranslation(_ translationX: CGFloat, session: TabSwipeSession) -> CGFloat {
        if (translationX > 0 && session.leftTab == nil) || (translationX < 0 && session.rightTab == nil) {
            return rubberBand(translationX, dimension: session.width)
        }
        return translationX
    }

    /// Standard diminishing-returns rubber-band (UIScrollView's curve): the offset asymptotically
    /// approaches `dimension` so a drag past the edge feels resisted, never free.
    private func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else { return 0 }
        let constant: CGFloat = 0.55
        let sign: CGFloat = offset < 0 ? -1 : 1
        let magnitude = abs(offset)
        return sign * (1 - 1 / (magnitude * constant / dimension + 1)) * dimension
    }

    private func clearTabSwipeSession(_ session: TabSwipeSession) {
        if tabSwipeSession === session { tabSwipeSession = nil }
    }
}
