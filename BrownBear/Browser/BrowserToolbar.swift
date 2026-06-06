//
//  BrowserToolbar.swift
//  BrownBear
//
//  The bottom toolbar — back, forward, new tab, the Chrome-style square tab-count button that
//  opens the grid, and the menu. State (enabled nav buttons, tab count) is pushed in; actions
//  go out through the delegate.
//

import UIKit

@MainActor
protocol BrowserToolbarDelegate: AnyObject {
    func toolbarDidTapBack(_ toolbar: BrowserToolbar)
    func toolbarDidTapForward(_ toolbar: BrowserToolbar)
    func toolbarDidTapNewTab(_ toolbar: BrowserToolbar)
    func toolbarDidTapTabs(_ toolbar: BrowserToolbar)
    func toolbarDidTapMenu(_ toolbar: BrowserToolbar)
}

@MainActor
final class BrowserToolbar: UIView {

    weak var delegate: BrowserToolbarDelegate?

    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let newTabButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)

    /// The tab-count control: a rounded square with the open-tab count, like Chrome iOS.
    private let tabsButton = UIButton(type: .system)
    private let tabsCountLabel = UILabel()
    private let tabsSquare = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public state

    func update(canGoBack: Bool, canGoForward: Bool, tabCount: Int) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        tabsCountLabel.text = tabCount > 99 ? ":D" : "\(tabCount)"
    }

    // MARK: - Build

    private func build() {
        backgroundColor = BrownBearTheme.Palette.chrome

        let topHairline = UIView()
        topHairline.backgroundColor = BrownBearTheme.Palette.separator
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topHairline)

        configureSymbol(backButton, "chevron.backward", #selector(tapBack))
        configureSymbol(forwardButton, "chevron.forward", #selector(tapForward))
        configureSymbol(newTabButton, "plus", #selector(tapNewTab))
        configureSymbol(menuButton, "ellipsis", #selector(tapMenu))

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

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.toolbarHeight)
        ])
    }

    private func configureSymbol(_ button: UIButton, _ symbol: String, _ action: Selector) {
        let config = UIImage.SymbolConfiguration(font: BrownBearTheme.Typography.toolbarSymbol())
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = BrownBearTheme.Palette.accent
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func buildTabsButton() {
        tabsSquare.layer.borderWidth = 2
        tabsSquare.layer.borderColor = BrownBearTheme.Palette.accent.cgColor
        tabsSquare.layer.cornerRadius = 5
        tabsSquare.layer.cornerCurve = .continuous
        tabsSquare.isUserInteractionEnabled = false
        tabsSquare.translatesAutoresizingMaskIntoConstraints = false

        tabsCountLabel.font = BrownBearTheme.Typography.tabCount()
        tabsCountLabel.textColor = BrownBearTheme.Palette.accent
        tabsCountLabel.textAlignment = .center
        tabsCountLabel.text = "1"
        tabsCountLabel.translatesAutoresizingMaskIntoConstraints = false

        tabsSquare.addSubview(tabsCountLabel)
        tabsButton.addSubview(tabsSquare)
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
