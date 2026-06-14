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
    /// verticalUp: the page snapshot that shrinks toward its grid card as you drag up.
    let hero: UIView?
    /// verticalUp: the page image (same as `hero`'s) handed to the grid on release so it can finish the
    /// shrink into the active card's real frame.
    let pageImage: UIImage?
    /// verticalUp: the page snapshot's full-screen start frame (the content area).
    let startFrame: CGRect
    /// verticalUp: the (approx) grid-card frame the page shrinks into.
    let targetFrame: CGRect
    /// verticalUp: guards the one-shot tab-grid open / teardown.
    var committed = false

    /// Horizontal tab-switch session.
    init(contentHolder: UIView, barHolder: UIView, width: CGFloat, leftTab: Tab?, rightTab: Tab?) {
        self.axis = .horizontal
        self.contentHolder = contentHolder
        self.barHolder = barHolder
        self.width = width
        self.leftTab = leftTab
        self.rightTab = rightTab
        self.hero = nil
        self.pageImage = nil
        self.startFrame = .zero
        self.targetFrame = .zero
    }

    /// Interactive swipe-up → tab grid: the page snapshot shrinks from `startFrame` toward `targetFrame`.
    init(hero: UIView, pageImage: UIImage?, startFrame: CGRect, targetFrame: CGRect) {
        self.axis = .verticalUp
        self.contentHolder = nil
        self.barHolder = nil
        self.width = 0
        self.leftTab = nil
        self.rightTab = nil
        self.hero = hero
        self.pageImage = pageImage
        self.startFrame = startFrame
        self.targetFrame = targetFrame
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
        // The carousel works by sliding an UN-clipped strip behind a CLIPPED viewport: the neighbour cards
        // live off-screen at ±width and are revealed as the strip translates. Clip the fixed viewport (the
        // content container) so they're masked to it; topChrome already clips for the bar strip.
        contentContainer.clipsToBounds = true
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
                beginVerticalUp()   // interactive shrink → tab grid
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

    // MARK: - Swipe up → tab grid (interactive shrink)

    /// Capture the page as an image-backed hero that shrinks toward its grid card as the finger drags up.
    /// The SAME image is handed to the grid on release so it can fly into the card 1:1 (an image, not a
    /// snapshot view, so it aspect-fills cleanly into the card instead of stretching).
    private func beginVerticalUp() {
        guard tabSwipeSession == nil else { return }
        let startFrame = contentContainer.frame
        guard startFrame.width > 0, let image = renderImage(of: contentContainer) else {
            // No snapshot — fall back to the plain (non-interactive) grid open on release.
            tabSwipeSession = TabSwipeSession(hero: UIView(), pageImage: nil,
                                              startFrame: .zero, targetFrame: .zero)
            return
        }
        let hero = UIImageView(image: image)
        hero.contentMode = .scaleAspectFill
        hero.frame = startFrame
        hero.layer.cornerCurve = .continuous
        hero.clipsToBounds = true

        // No dimming backdrop — iOS Safari shrinks the page over the chrome without darkening it. The page
        // (hero) shrinks over the content container's own background; the toolbar/address bar stay put.
        view.addSubview(hero)
        contentContainer.isHidden = true   // only the shrinking snapshot shows during the drag

        tabSwipeSession = TabSwipeSession(hero: hero, pageImage: image, startFrame: startFrame,
                                          targetFrame: tabGridCardTargetFrame(from: startFrame))
    }

    /// Approximate where the active tab's card sits in the grid (centred, ~2-column card size). The grid
    /// centres the active tab on open, so a centred target lands close; tuned on device.
    private func tabGridCardTargetFrame(from start: CGRect) -> CGRect {
        // Where the page shrinks toward as you drag up. iOS Safari doesn't lock it dead-centre — the page
        // pulls FARTHER away (smaller) and sits a bit HIGHER, heading toward the grid above. So target a
        // smaller card centred at ~40% of the height. (This is just the interactive preview — on release the
        // page flies to the active card's REAL frame, so the exact value only sets the drag feel.)
        let cardWidth = view.bounds.width * 0.40
        let aspect = start.height > 0 ? start.width / start.height : 0.6
        let cardHeight = aspect > 0 ? cardWidth / aspect : cardWidth * 1.5
        return CGRect(x: (view.bounds.width - cardWidth) / 2,
                      y: view.bounds.height * 0.40 - cardHeight / 2,
                      width: cardWidth, height: cardHeight)
    }

    private func updateVerticalUp(translationY: CGFloat, session: TabSwipeSession) {
        guard !session.committed, let hero = session.hero, session.startFrame != .zero else { return }
        // The up-drag drives the shrink 0→1 over ~⅓ of the screen height; the page tracks the finger.
        let distance = max(view.bounds.height / 3, 1)
        let progress = min(max(-translationY / distance, 0), 1)
        hero.frame = interpolate(session.startFrame, session.targetFrame, progress)
        hero.layer.cornerRadius = progress * BrownBearTheme.Metrics.cellCornerRadius
    }

    private func finishVerticalUp(translationY: CGFloat, velocityY: CGFloat, session: TabSwipeSession) {
        // Fallback (no snapshot): just open the grid on a committed up-swipe.
        guard let hero = session.hero, session.startFrame != .zero else {
            if translationY < -tabSwipeUpThreshold || velocityY < -800 { toolbarDidTapTabs(toolbar) }
            clearTabSwipeSession(session)
            return
        }
        session.committed = true
        let distance = max(view.bounds.height / 3, 1)
        let progress = min(max(-translationY / distance, 0), 1)

        if progress > 0.4 || velocityY < -700 {
            // Hand the page off to the grid: present it (no built-in transition) and let it finish the shrink
            // from where the finger let go into the active card's REAL frame — no approximation, no snap.
            let releaseFrame = view.convert(hero.frame, to: nil)
            let corner = hero.layer.cornerRadius
            hero.removeFromSuperview()
            contentContainer.isHidden = false
            if let image = session.pageImage {
                presentTabGridWithoutAnimation { grid in
                    grid.prepareFlyIn(image: image, fromWindowFrame: releaseFrame, cornerRadius: corner)
                }
            } else {
                presentTabGrid()
            }
            clearTabSwipeSession(session)
        } else {
            // Spring the page back to full screen — nothing opens.
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                           options: [.curveEaseOut]) {
                hero.frame = session.startFrame
                hero.layer.cornerRadius = 0
            } completion: { [weak self] _ in
                self?.contentContainer.isHidden = false
                hero.removeFromSuperview()
                self?.clearTabSwipeSession(session)
            }
        }
    }

    /// Tab-icon press: the SAME shrink-into-card motion as the interactive swipe-up, just non-interactive.
    /// The grid is presented (no built-in transition) and flies the full-screen page snapshot down into the
    /// active card's real frame — so tapping the tab button and swiping up land in the same place, the same way.
    func animateTabGridShrink() {
        guard tabSwipeSession == nil else { return }   // don't fire mid-swipe
        let startFrame = contentContainer.frame
        guard startFrame.width > 0, let image = renderImage(of: contentContainer) else {
            presentTabGrid()   // can't snapshot — plain animated present
            return
        }
        let releaseFrame = view.convert(startFrame, to: nil)
        presentTabGridWithoutAnimation { grid in
            grid.prepareFlyIn(image: image, fromWindowFrame: releaseFrame, cornerRadius: 0)
        }
    }

    /// Render a view's current contents to an image — the page hero for the swipe-up shrink and the grid
    /// hand-off both use it, so the same picture shrinks and then flies into the card.
    private func renderImage(of target: UIView) -> UIImage? {
        guard target.bounds.width > 0, target.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: target.bounds, format: format)
        return renderer.image { _ in
            target.drawHierarchy(in: target.bounds, afterScreenUpdates: false)
        }
    }

    private func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
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

        // Content strip: previous | current | next, current centred. NOT clipped — the neighbours sit at
        // ±width and must show as the strip slides; the content container (clipped above) masks the
        // overflow. Clipping the strip itself would hide the neighbours AND expose the live web view in
        // the vacated area (the "mirror of the active tab" bug) instead of the neighbour's card.
        let contentHolder = UIView(frame: bounds)
        contentHolder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentHolder.clipsToBounds = false
        contentHolder.isUserInteractionEnabled = false
        // Opaque backstop in the centre region so the live web view never peeks through if the centre
        // snapshot is ever blank.
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
        barHolder.clipsToBounds = false   // topChrome clips the bar strip; the holder must not clip its neighbours
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
