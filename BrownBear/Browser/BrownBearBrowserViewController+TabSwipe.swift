//
//  BrownBearBrowserViewController+TabSwipe.swift
//  BrownBear
//
//  Safari-style "swipe the address bar to change tabs". A horizontal pan on the omnibox bar (topChrome)
//  interactively slides the current tab off and the ADJACENT tab in, using each tab's already-captured
//  snapshot so the neighbour appears instantly "preloaded" — no flash, no wait. On release the gesture
//  commits to the neighbour (past a distance/velocity threshold) or springs back.
//
//  Why the bar and not the page: WKWebView owns its own interactive back/forward edge-swipe; driving tab
//  switching from the page would fight it. Anchoring the gesture to the address bar (exactly what the user
//  reaches for) keeps the two completely separate. The pan never cancels touches, so tapping the bar to
//  edit the URL still works; it only begins on a clearly-horizontal drag while not editing.
//
//  The neighbour set is the active tab's OWN privacy set (normal vs private), matching the tab grid — a
//  private tab swipes among private tabs only. The live web-view swap happens through the normal
//  TabManager.setActiveTab path once the slide settles; the snapshot overlay covers the swap, then fades.
//

import UIKit

/// Transient state for one in-flight address-bar swipe. Lives only between `.began` and the settle
/// animation's completion; `BrownBearBrowserViewController.tabSwipeSession` is nil whenever idle.
final class TabSwipeSession {
    /// The overlay holding the three side-by-side layers (previous | current | next); translated by the pan.
    let holder: UIView
    /// The content width one tab occupies — the full commit translation and rubber-band reference.
    let width: CGFloat
    /// The tab revealed by a rightward swipe (the one before the active tab), or nil at the left edge.
    let leftTab: Tab?
    /// The tab revealed by a leftward swipe (the one after the active tab), or nil at the right edge.
    let rightTab: Tab?

    init(holder: UIView, width: CGFloat, leftTab: Tab?, rightTab: Tab?) {
        self.holder = holder
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
        guard bounds.width > 0 else { return }

        let holder = UIView(frame: bounds)
        holder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        holder.clipsToBounds = true
        holder.isUserInteractionEnabled = false
        holder.backgroundColor = BrownBearTheme.Palette.background

        // Centre layer: a live snapshot of what's on screen right now (the current tab).
        let centre = contentContainer.snapshotView(afterScreenUpdates: false) ?? UIView(frame: bounds)
        centre.frame = bounds
        holder.addSubview(centre)

        let index = neighbours.index
        let set = neighbours.set
        let leftTab = index > 0 ? set[index - 1] : nil
        let rightTab = index < set.count - 1 ? set[index + 1] : nil
        holder.addSubview(tabSwipeLayer(for: leftTab, frame: bounds.offsetBy(dx: -bounds.width, dy: 0)))
        holder.addSubview(tabSwipeLayer(for: rightTab, frame: bounds.offsetBy(dx: bounds.width, dy: 0)))

        contentContainer.addSubview(holder)
        tabSwipeSession = TabSwipeSession(holder: holder, width: bounds.width, leftTab: leftTab, rightTab: rightTab)
    }

    private func updateTabSwipe(translationX: CGFloat) {
        guard let session = tabSwipeSession else { return }
        var dx = translationX
        // Resist (rubber-band) when there is no tab to reveal in that direction, so an edge tab can't be
        // dragged into empty space.
        if (dx > 0 && session.leftTab == nil) || (dx < 0 && session.rightTab == nil) {
            dx = rubberBand(dx, dimension: session.width)
        }
        session.holder.transform = CGAffineTransform(translationX: dx, y: 0)
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
            // No commit: spring the current tab back to centre and tear the overlay down.
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                session.holder.transform = .identity
            } completion: { [weak self] _ in
                session.holder.removeFromSuperview()
                self?.clearTabSwipeSession(session)
            }
            return
        }

        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            session.holder.transform = CGAffineTransform(translationX: settle, y: 0)
        } completion: { [weak self] _ in
            guard let self else { return }
            // Swap in the neighbour's LIVE web view behind the (now full-screen) snapshot, then fade the
            // snapshot out to reveal it — no flash, since the live view is already in place underneath.
            self.tabManager.setActiveTab(target)
            self.contentContainer.bringSubviewToFront(session.holder)
            UIView.animate(withDuration: 0.18) {
                session.holder.alpha = 0
            } completion: { _ in
                session.holder.removeFromSuperview()
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

    /// One slide layer for a neighbour tab: its snapshot if it has one, else a plain themed panel (a
    /// never-shown tab has no render yet — the panel reads as "a tab", and the live view loads on commit).
    private func tabSwipeLayer(for tab: Tab?, frame: CGRect) -> UIView {
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
