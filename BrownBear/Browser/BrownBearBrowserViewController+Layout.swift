//
//  BrownBearBrowserViewController+Layout.swift
//  BrownBear
//
//  Builds the browser chrome hierarchy (top omnibox bar, progress bar, web content area, bottom
//  toolbar, suggestions overlay) and its Auto Layout constraints. Split out of the main controller so
//  the controller stays under the SwiftLint length limit and so the scroll-hide machinery
//  (+ScrollChrome) has a clear, named set of constraints to animate.
//
//  The omnibox is pinned inside `topChrome` (not directly to the view's safe area), and topChrome is
//  anchored to the very top with an animatable HEIGHT. Scroll-hide collapses that height to the
//  safe-area strip so the bar rolls away while the status-bar / Dynamic Island region keeps its chrome
//  backing. At rest the height equals omnibox.bottom + 8, so the resting layout is unchanged.
//

import UIKit

extension BrownBearBrowserViewController {

    /// Compose the chrome subviews and activate their constraints. Called once from viewDidLoad.
    func buildHierarchy() {
        topChrome.backgroundColor = BrownBearTheme.Palette.chrome
        // Clip so the omnibox is hidden when the bar collapses to the safe-area strip on scroll.
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

        // Suggestions overlay the page between the bar and the toolbar; added last so it sits on top.
        omniboxSuggestions.delegate = self
        omniboxSuggestions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(omniboxSuggestions)

        let inset = BrownBearTheme.Metrics.chromeHorizontalInset
        let guide = view.safeAreaLayoutGuide

        // The top chrome stays pinned to the very top (covering the status bar / Dynamic Island); the
        // scroll-hide animation drives its HEIGHT — full when shown, just the safe-area strip when
        // hidden — and the omnibox (pinned inside, clipped) rolls away with it. At rest the height equals
        // omnibox.bottom + 8, so the resting layout is unchanged.
        let omniboxTop = omnibox.topAnchor.constraint(equalTo: topChrome.topAnchor,
                                                      constant: view.safeAreaInsets.top + 8)
        let fullHeight = view.safeAreaInsets.top + BrownBearTheme.Metrics.omniboxHeight + 16
        let heightConstraint = topChrome.heightAnchor.constraint(equalToConstant: fullHeight)
        topChromeHeightConstraint = heightConstraint
        omniboxTopConstraint = omniboxTop

        NSLayoutConstraint.activate([
            topChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topChrome.topAnchor.constraint(equalTo: view.topAnchor),
            heightConstraint,

            omnibox.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset),
            omnibox.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset),
            omniboxTop,
            omnibox.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.omniboxHeight),

            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: topChrome.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.progressBarHeight),

            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: guide.bottomAnchor,
                                         constant: -BrownBearTheme.Metrics.toolbarHeight),

            omniboxSuggestions.topAnchor.constraint(equalTo: progressBar.bottomAnchor),
            omniboxSuggestions.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            omniboxSuggestions.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            omniboxSuggestions.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        ])
    }
}
