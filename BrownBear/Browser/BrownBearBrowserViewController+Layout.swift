//
//  BrownBearBrowserViewController+Layout.swift
//  BrownBear
//
//  Builds the browser chrome hierarchy (omnibox bar, progress bar, web content area, toolbar,
//  suggestions overlay) and its Auto Layout constraints, supporting BOTH address-bar positions:
//
//   • Top (default, Chrome-style): the omnibox bar is at the top. Scroll-hide collapses its HEIGHT to
//     the safe-area strip so the bar rolls away while the status-bar / Dynamic Island region keeps its
//     chrome backing and the page never slides under it. The toolbar stays put.
//   • Bottom (Safari-style): the omnibox sits just above the toolbar. Scroll-hide slides the whole
//     bottom chrome (omnibox + toolbar) down off-screen together; the page grows to fill.
//
//  Both modes share the omnibox/progress/content/toolbar views and a common set of constraints; a
//  per-position set (topPositionConstraints / bottomPositionConstraints) is swapped by
//  applyAddressBarPosition when the preference changes (live, via .brownBearChromeLayoutChanged).
//

import UIKit

extension BrownBearBrowserViewController {

    /// The omnibox bar's height excluding the safe area (omnibox + 8pt top/bottom padding).
    var omniboxBarHeight: CGFloat { BrownBearTheme.Metrics.omniboxHeight + 16 }

    /// Compose the chrome subviews and activate their constraints. Called once from viewDidLoad.
    func buildHierarchy() {
        topChrome.backgroundColor = BrownBearTheme.Palette.chrome
        // Clip so the omnibox is hidden when the top bar collapses to the safe-area strip on scroll.
        topChrome.clipsToBounds = true
        topChrome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topChrome)

        omnibox.translatesAutoresizingMaskIntoConstraints = false
        topChrome.addSubview(omnibox)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        contentContainer.backgroundColor = BrownBearTheme.Palette.background
        contentContainer.clipsToBounds = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        // Bottom-mode collapsed strip: a chrome-coloured bar that fills the home-indicator area with the
        // site's domain shown above the safe area. Hidden (alpha 0) until the bottom bar scroll-hides;
        // tapping it brings the full bar back. Added before the suggestions so those still overlay it.
        collapsedBottomBar.backgroundColor = BrownBearTheme.Palette.chrome
        collapsedBottomBar.alpha = 0
        collapsedBottomBar.isUserInteractionEnabled = true
        collapsedBottomBar.translatesAutoresizingMaskIntoConstraints = false
        collapsedBottomBar.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(expandBottomBarFromCollapsed)))
        view.addSubview(collapsedBottomBar)
        // The SSL lock sits just left of the domain, like the omnibox's leading glyph. A fixed symbol
        // config so it can't grow with Dynamic Type and unbalance the centred pill.
        collapsedLockGlyph.contentMode = .scaleAspectFit
        collapsedLockGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        collapsedLockGlyph.setContentHuggingPriority(.required, for: .horizontal)
        collapsedHostLabel.font = .systemFont(ofSize: 13, weight: .medium)
        collapsedHostLabel.textColor = .secondaryLabel
        collapsedHostLabel.textAlignment = .center
        // The domain yields (truncates) before the lock does, so a long host can't push the lock off-centre.
        collapsedHostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        collapsedHostStack.axis = .horizontal
        collapsedHostStack.alignment = .center
        collapsedHostStack.spacing = 5
        collapsedHostStack.translatesAutoresizingMaskIntoConstraints = false
        collapsedHostStack.addArrangedSubview(collapsedLockGlyph)
        collapsedHostStack.addArrangedSubview(collapsedHostLabel)
        collapsedBottomBar.addSubview(collapsedHostStack)

        // Suggestions overlay the page next to the bar; added last so it sits on top.
        omniboxSuggestions.delegate = self
        omniboxSuggestions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(omniboxSuggestions)

        let inset = BrownBearTheme.Metrics.chromeHorizontalInset
        let guide = view.safeAreaLayoutGuide
        let omniboxH = BrownBearTheme.Metrics.omniboxHeight

        // The omnibox is pinned INSIDE topChrome so the whole bar moves as one unit; the offset + the
        // bar height track the safe-area inset (set per-position in applyAddressBarPosition).
        let omniboxTop = omnibox.topAnchor.constraint(equalTo: topChrome.topAnchor,
                                                      constant: view.safeAreaInsets.top + 8)
        let heightConstraint = topChrome.heightAnchor.constraint(equalToConstant: view.safeAreaInsets.top + omniboxH + 16)
        omniboxTopConstraint = omniboxTop
        topChromeHeightConstraint = heightConstraint

        // Common constraints — true in both positions.
        NSLayoutConstraint.activate([
            topChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,

            omnibox.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
            omnibox.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            omniboxTop,
            omnibox.heightAnchor.constraint(equalToConstant: omniboxH),

            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.progressBarHeight),

            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.toolbarHeight),

            omniboxSuggestions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            omniboxSuggestions.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Collapsed bottom strip: fills from ~36pt above the safe-area bottom down to the screen edge
        // (so the home-indicator strip is chrome-coloured, not bare). The lock + domain sit centred and a
        // little lower — vertically centred in the band just above the safe area, Safari-style — rather
        // than hugging the top. Same in both positions; kept at alpha 0 unless the bottom bar is hidden.
        NSLayoutConstraint.activate([
            collapsedBottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collapsedBottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collapsedBottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collapsedBottomBar.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: -36),
            collapsedHostStack.centerYAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
            collapsedHostStack.centerXAnchor.constraint(equalTo: collapsedBottomBar.centerXAnchor),
            collapsedHostStack.leadingAnchor.constraint(greaterThanOrEqualTo: collapsedBottomBar.leadingAnchor, constant: 16),
            collapsedHostStack.trailingAnchor.constraint(lessThanOrEqualTo: collapsedBottomBar.trailingAnchor, constant: -16)
        ])

        // Top-position: bar at the top, toolbar fixed at the bottom.
        topPositionConstraints = [
            topChrome.topAnchor.constraint(equalTo: view.topAnchor),
            progressBar.topAnchor.constraint(equalTo: topChrome.bottomAnchor),
            contentContainer.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            omniboxSuggestions.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            omniboxSuggestions.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        ]

        // Bottom-position: progress bar at the top (below the island), omnibox above the toolbar, and
        // the toolbar's bottom is the animatable anchor the bottom chrome slides on.
        let toolbarBottom = toolbar.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        bottomChromeBottomConstraint = toolbarBottom
        bottomPositionConstraints = [
            progressBar.topAnchor.constraint(equalTo: guide.topAnchor),
            contentContainer.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: topChrome.topAnchor),
            topChrome.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarBottom,
            omniboxSuggestions.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            omniboxSuggestions.bottomAnchor.constraint(equalTo: topChrome.topAnchor)
        ]

        applyAddressBarPosition(AppSettings.addressBarPosition, animated: false)
    }

    /// Activate the constraint set for `position`, update the position-dependent constants, and reset the
    /// chrome to fully shown. Called at build and whenever the preference changes (animated when live).
    func applyAddressBarPosition(_ position: AddressBarPosition, animated: Bool) {
        NSLayoutConstraint.deactivate(topPositionConstraints)
        NSLayoutConstraint.deactivate(bottomPositionConstraints)

        let safeTop = view.safeAreaInsets.top
        let omniboxH = BrownBearTheme.Metrics.omniboxHeight
        switch position {
        case .top:
            NSLayoutConstraint.activate(topPositionConstraints)
            omniboxTopConstraint?.constant = safeTop + 8           // sit below the status bar
            topChromeHeightConstraint?.constant = safeTop + omniboxH + 16
        case .bottom:
            NSLayoutConstraint.activate(bottomPositionConstraints)
            omniboxTopConstraint?.constant = 8                     // no status bar above it at the bottom
            topChromeHeightConstraint?.constant = omniboxH + 16
        }

        // Come back fully shown in the new layout — but preserve an in-progress keyboard lift (a
        // safe-area change / rotation while editing the bottom bar re-applies the position; without this
        // the bar would drop back behind the keyboard).
        chromeHidden = false
        omnibox.alpha = 1
        collapsedBottomBar.alpha = 0   // fully shown in the new layout → no collapsed strip
        collapsedHostStack.transform = .identity   // clear any in-flight slide-down offset
        bottomChromeBottomConstraint?.constant = keyboardVisible ? -keyboardLiftOverlap : 0

        guard animated else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }
}
