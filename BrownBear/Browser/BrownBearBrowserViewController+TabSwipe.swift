//
//  BrownBearBrowserViewController+TabSwipe.swift
//  BrownBear
//
//  Safari-style bottom-bar gestures on the address bar:
//
//   • Swipe LEFT/RIGHT — the page + its address-bar pill track your finger 1:1 like a horizontal carousel
//     of cards, the neighbour tab sliding in from the opposite edge (drag right → the PREVIOUS tab comes in
//     from the left; drag left → the NEXT tab comes in from the right). Release past ~halfway OR with a
//     flick to complete (a velocity-aware spring carries it); short and slow springs back; an edge tab
//     rubber-bands. Each tab carries its own URL pill, so the bars drift with their pages.
//
//   • Swipe UP — opens the tab switcher (the page settles into its grid card via the existing zoom
//     transition). A deliberate up-drag (or an upward flick) on the bar triggers it.
//
//  Anchored to the address bar (topChrome), NOT the page, so it never fights WKWebView's own back/forward
//  edge-swipe. The pan never cancels touches, so tapping the bar to edit the URL still works; it only begins
//  on a clearly-horizontal drag (with a neighbour) or a clearly-upward drag, and never while editing.
//

import UIKit

/// Transient state for one in-flight bar gesture. Lives only between `.began` and the settle animation's
/// completion; `BrownBearBrowserViewController.tabSwipeSession` is nil whenever idle.
final class TabSwipeSession {
    enum Axis { case horizontal, verticalUp }
    let axis: Axis
    /// Content overlay (previous | current | next) — horizontal only.
    let contentHolder: UIView?
    /// Matching address-bar overlay, translated in lockstep with content — horizontal only.
    let barHolder: UIView?
    /// The content width one tab occupies — the full commit translation and rubber-band reference.
    let width: CGFloat
    /// The tab revealed by a rightward swipe (the one before the active tab), or nil at the left edge.
    let leftTab: Tab?
    /// The tab revealed by a leftward swipe (the one after the active tab), or nil at the right edge.
    let rightTab: Tab?
    /// verticalUp: guards the one-shot tab-grid open.
    var gridOpened = false

    /// Horizontal tab-switch session.
    init(contentHolder: UIView, barHolder: UIView, width: CGFloat, leftTab: Tab?, rightTab: Tab?) {
        self.axis = .horizontal
        self.contentHolder = contentHolder
        self.barHolder = barHolder
        self.width = width
        self.leftTab = leftTab
        self.rightTab = rightTab
    }

    /// Vertical (swipe-up → tab grid) session — no overlays.
    init() {
        self.axis = .verticalUp
        self.contentHolder = nil
        self.barHolder = nil
        self.width = 0
        self.leftTab = nil
        self.rightTab = nil
    }
}

extension BrownBearBrowserViewController: UIGestureRecognizerDelegate {

    /// Distance you must drag up before a release opens the tab grid (also the mid-drag trigger).
    private var tabSwipeUpThreshold: CGFloat { 70 }

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

    /// Begin on a clearly-horizontal drag (with a same-privacy neighbour to switch to) OR a clearly-upward
    /// drag (to open the tab grid), while not editing the URL.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === tabSwipePan else { return true }
        guard tabSwipeSession == nil, !omnibox.isEditingURL else { return false }
        let velocity = tabSwipePan.velocity(in: topChrome)
        if abs(velocity.y) > abs(velocity.x) {
            return velocity.y < 0   // upward → tab grid (always allowed, even with one tab)
        }
        guard let neighbours = tabSwipeNeighbours(), neighbours.set.count > 1 else { return false }
        return true
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
            let velocity = pan.velocity(in: contentContainer)
            if abs(velocity.y) > abs(velocity.x) {
                tabSwipeSession = TabSwipeSession()   // verticalUp → tab grid
            } else {
                beginTabSwipe()
            }
        case .changed:
            guard let session = tabSwipeSession else { return }
            if session.axis == .verticalUp {
                updateVerticalUp(translationY: pan.translation(in: contentContainer).y, session: session)
            } else {
                updateTabSwipe(translationX: pan.translation(in: contentContainer).x)
            }
        case .ended, .cancelled, .failed:
            guard let session = tabSwipeSession else { return }
            if session.axis == .verticalUp {
                finishVerticalUp(translationY: pan.translation(in: contentContainer).y,
                                 velocityY: pan.velocity(in: contentContainer).y, session: session)
            } else {
                finishTabSwipe(translationX: pan.translation(in: contentContainer).x,
                               velocityX: pan.velocity(in: contentContainer).x)
            }
        default:
            break
        }
    }

    // MARK: - Swipe up → tab grid

    private func updateVerticalUp(translationY: CGFloat, session: TabSwipeSession) {
        // Open the grid as soon as the up-drag is committed, so it feels responsive (the grid's own zoom
        // transition then settles the page into its card).
        guard !session.gridOpened, translationY < -tabSwipeUpThreshold else { return }
        session.gridOpened = true
        toolbarDidTapTabs(toolbar)
    }

    private func finishVerticalUp(translationY: CGFloat, velocityY: CGFloat, session: TabSwipeSession) {
        if !session.gridOpened, translationY < -tabSwipeUpThreshold || velocityY < -800 {
            session.gridOpened = true
            toolbarDidTapTabs(toolbar)
        }
        clearTabSwipeSession(session)
    }

    // MARK: - Swipe left/right → tab switch

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
        guard let session = tabSwipeSession,
              let contentHolder = session.contentHolder, let barHolder = session.barHolder else { return }
        let dx = effectiveTranslation(translationX, session: session)
        let transform = CGAffineTransform(translationX: dx, y: 0)
        contentHolder.transform = transform
        barHolder.transform = transform
    }

    private func finishTabSwipe(translationX: CGFloat, velocityX: CGFloat) {
        guard let session = tabSwipeSession,
              let contentHolder = session.contentHolder, let barHolder = session.barHolder else { return }
        let width = session.width
        let distanceThreshold = width * 0.5      // commit past roughly halfway…
        let flingThreshold: CGFloat = 500        // …or on a flick, even a short one.

        // Drag RIGHT (positive) reveals the PREVIOUS (left) tab from the left edge; drag LEFT reveals the
        // NEXT (right) tab from the right edge — the content moves WITH the finger (Safari carousel).
        var target: Tab?
        var settle: CGFloat = 0
        if (translationX > distanceThreshold || velocityX > flingThreshold), let left = session.leftTab {
            target = left
            settle = width
        } else if (translationX < -distanceThreshold || velocityX < -flingThreshold), let right = session.rightTab {
            target = right
            settle = -width
        }

        let current = effectiveTranslation(translationX, session: session)
        let destination = target == nil ? 0 : settle
        let springVelocity = springVelocity(for: velocityX, from: current, to: destination)

        guard let target else {
            // No commit: spring content and bar back to centre together, then tear the overlays down.
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82,
                           initialSpringVelocity: springVelocity,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                contentHolder.transform = .identity
                barHolder.transform = .identity
            } completion: { [weak self] _ in
                contentHolder.removeFromSuperview()
                barHolder.removeFromSuperview()
                self?.clearTabSwipeSession(session)
            }
            return
        }

        let settleTransform = CGAffineTransform(translationX: settle, y: 0)
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86,
                       initialSpringVelocity: springVelocity,
                       options: [.curveEaseOut, .allowUserInteraction]) {
            contentHolder.transform = settleTransform
            barHolder.transform = settleTransform
        } completion: { [weak self] _ in
            guard let self else { return }
            // Swap in the neighbour's LIVE web view (and refresh the real omnibox to its URL) behind the
            // now-full-screen snapshots, then fade the overlays out to reveal them — no flash.
            self.tabManager.setActiveTab(target)
            self.contentContainer.bringSubviewToFront(contentHolder)
            self.topChrome.bringSubviewToFront(barHolder)
            UIView.animate(withDuration: 0.18) {
                contentHolder.alpha = 0
                barHolder.alpha = 0
            } completion: { _ in
                contentHolder.removeFromSuperview()
                barHolder.removeFromSuperview()
            }
            self.clearTabSwipeSession(session)
        }
    }

    // MARK: - Helpers

    /// A normalized initial spring velocity (UIView spring units = fraction of the remaining distance per
    /// second) from the pan's point/sec velocity, so a fast flick keeps its momentum into the settle.
    private func springVelocity(for velocityX: CGFloat, from current: CGFloat, to destination: CGFloat) -> CGFloat {
        let remaining = abs(destination - current)
        guard remaining > 1 else { return 0 }
        return min(abs(velocityX) / remaining, 6)
    }

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
