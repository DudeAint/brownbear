//
//  BrowserToolbar.swift
//  BrownBear
//
//  The bottom toolbar — back, forward, new tab, the Chrome-style square tab-count button that
//  opens the grid, and the menu. Every glyph is a `ToolbarButton`, so the chrome shares one
//  state→token tinting model: resting glyphs are NEUTRAL (iconPrimary), accent is reserved for
//  the pressed/selected state, and disabled dims. Symbols are Dynamic-Type-scaled; the tab count
//  crossfades when it changes. State (enabled nav buttons, tab count) is pushed in; actions go
//  out through the delegate.
//

import UIKit

@MainActor
protocol BrowserToolbarDelegate: AnyObject {
    func toolbarDidTapBack(_ toolbar: BrowserToolbar)
    func toolbarDidTapForward(_ toolbar: BrowserToolbar)
    func toolbarDidTapNewTab(_ toolbar: BrowserToolbar)
    func toolbarDidTapTabs(_ toolbar: BrowserToolbar)
    func toolbarDidTapMenu(_ toolbar: BrowserToolbar)
    /// Long-press affordances (Firefox/Brave pattern): back/forward show the per-tab history list;
    /// the new-tab button offers New Private Tab.
    func toolbarDidLongPressBack(_ toolbar: BrowserToolbar)
    func toolbarDidLongPressForward(_ toolbar: BrowserToolbar)
    func toolbarDidLongPressNewTab(_ toolbar: BrowserToolbar)
}

@MainActor
final class BrowserToolbar: UIView {

    weak var delegate: BrowserToolbarDelegate?

    private let backButton = ToolbarButton()
    private let forwardButton = ToolbarButton()
    private let newTabButton = ToolbarButton()
    private let menuButton = ToolbarButton()

    /// The tab-count control: a rounded square with the open-tab count, like Chrome iOS. It is a
    /// `ToolbarButton` for layout/haptic parity, hosting a bordered square + count label as subviews.
    private let tabsButton = ToolbarButton()
    private let tabsCountLabel = UILabel()
    private let tabsSquare = UIView()

    /// Glyph point size before Dynamic-Type scaling (matches the prior fixed 20pt look).
    private static let glyphPointSize: CGFloat = 20

    /// The count currently shown, so we only animate on a real change.
    private var displayedTabCount = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public state

    /// The view a toolbar-triggered popover (e.g. an extension's action popup) anchors to. Extensions
    /// live in the "•••" menu today, so their popup springs from that button — the toolbar is always at
    /// the bottom, so the popover rises up over the page. (Re-anchors to a dedicated icon if one is added.)
    var actionAnchorView: UIView { menuButton }

    func update(canGoBack: Bool, canGoForward: Bool, tabCount: Int) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        setTabCount(tabCount)
    }

    /// Update the tab-count badge, crossfading the number when it changes (no animation off-screen).
    private func setTabCount(_ count: Int) {
        guard count != displayedTabCount else { return }
        displayedTabCount = count
        let text = count > 99 ? ":D" : "\(count)"
        tabsButton.accessibilityValue = "\(count) open"
        guard window != nil else { tabsCountLabel.text = text; return }
        UIView.transition(with: tabsCountLabel,
                          duration: BrownBearTheme.Motion.crossfade,
                          options: [.transitionCrossDissolve, .beginFromCurrentState]) {
            self.tabsCountLabel.text = text
        }
        // A small spring pop on the square draws the eye to the change (new/closed tab).
        tabsSquare.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
        UIView.animate(withDuration: 0.40, delay: 0,
                       usingSpringWithDamping: 0.5, initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.tabsSquare.transform = .identity
        }
    }

    // MARK: - Build

    private func build() {
        backgroundColor = BrownBearTheme.Palette.surfaceRaised

        let topHairline = UIView()
        topHairline.backgroundColor = BrownBearTheme.Palette.borderSubtle
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topHairline)

        configure(backButton, symbol: "chevron.backward", label: "Back", action: #selector(tapBack))
        configure(forwardButton, symbol: "chevron.forward", label: "Forward", action: #selector(tapForward))
        configure(newTabButton, symbol: "plus", label: "New Tab", action: #selector(tapNewTab))
        configure(menuButton, symbol: "ellipsis", label: "More", action: #selector(tapMenu))

        // Back/forward long-press shows the per-tab history list (ToolbarButton's built-in handler).
        backButton.longPressHandler = { [weak self] in
            guard let self else { return }
            self.delegate?.toolbarDidLongPressBack(self)
        }
        forwardButton.longPressHandler = { [weak self] in
            guard let self else { return }
            self.delegate?.toolbarDidLongPressForward(self)
        }
        // New-tab button: a TAP opens a regular tab; a LONG-PRESS pops a small menu attached to the
        // button offering New Tab / New Private Tab — so private mode is a visible choice rather than a
        // blind "hold = private". Remove ToolbarButton's own long-press recognizer first so it doesn't
        // fight UIButton's menu interaction.
        newTabButton.gestureRecognizers?
            .filter { $0 is UILongPressGestureRecognizer }
            .forEach { newTabButton.removeGestureRecognizer($0) }
        newTabButton.menu = UIMenu(children: [
            UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.toolbarDidTapNewTab(self)
            },
            UIAction(title: "New Private Tab", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.toolbarDidLongPressNewTab(self)
            }
        ])
        newTabButton.showsMenuAsPrimaryAction = false

        buildTabsButton()

        let stack = UIStackView(arrangedSubviews: [backButton, forwardButton, newTabButton, tabsButton, menuButton])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.hairline),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BrownBearTheme.Space.xs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BrownBearTheme.Space.xs),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.toolbarHeight)
        ])
    }

    private func configure(_ button: ToolbarButton, symbol: String, label: String, action: Selector) {
        button.setSymbol(symbol, pointSize: Self.glyphPointSize)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func buildTabsButton() {
        // The tab-count square stays amber — it is the chrome's one brand signature (Chrome iOS),
        // the deliberate exception to the otherwise-neutral resting glyphs.
        tabsSquare.layer.borderWidth = 2
        tabsSquare.layer.borderColor = BrownBearTheme.Palette.accent.cgColor
        tabsSquare.layer.cornerRadius = 5
        tabsSquare.layer.cornerCurve = .continuous
        tabsSquare.isUserInteractionEnabled = false
        tabsSquare.translatesAutoresizingMaskIntoConstraints = false

        // Fixed size: the badge lives inside a fixed 24pt square, so the count stays fixed-size to
        // avoid overflow at large accessibility text settings.
        tabsCountLabel.font = BrownBearTheme.Typography.tabCount()
        tabsCountLabel.textColor = BrownBearTheme.Palette.accent
        tabsCountLabel.textAlignment = .center
        tabsCountLabel.text = "1"
        tabsCountLabel.translatesAutoresizingMaskIntoConstraints = false

        tabsSquare.addSubview(tabsCountLabel)
        tabsButton.addSubview(tabsSquare)
        tabsButton.accessibilityLabel = "Show Tabs"
        tabsButton.addTarget(self, action: #selector(tapTabs), for: .touchUpInside)

        NSLayoutConstraint.activate([
            tabsSquare.centerXAnchor.constraint(equalTo: tabsButton.centerXAnchor),
            tabsSquare.centerYAnchor.constraint(equalTo: tabsButton.centerYAnchor),
            tabsSquare.widthAnchor.constraint(equalToConstant: 24),
            tabsSquare.heightAnchor.constraint(equalToConstant: 24),
            tabsCountLabel.centerXAnchor.constraint(equalTo: tabsSquare.centerXAnchor),
            tabsCountLabel.centerYAnchor.constraint(equalTo: tabsSquare.centerYAnchor)
        ])
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // CGColor must be refreshed when light/dark appearance changes.
        tabsSquare.layer.borderColor = BrownBearTheme.Palette.accent.cgColor
    }

    // MARK: - Actions

    @objc private func tapBack() { delegate?.toolbarDidTapBack(self) }
    @objc private func tapForward() { delegate?.toolbarDidTapForward(self) }
    @objc private func tapNewTab() { delegate?.toolbarDidTapNewTab(self) }
    @objc private func tapTabs() { delegate?.toolbarDidTapTabs(self) }
    @objc private func tapMenu() { delegate?.toolbarDidTapMenu(self) }
}
