//
//  BrowserMenuViewController.swift
//  BrownBear
//
//  The browser's "•••" menu — a reference-grade bottom sheet (Safari/Arc/Firefox style) instead of a
//  plain action sheet: a header with the page identity, a row of large icon tiles for the primary
//  actions, and a list of secondary actions with leading icons and live state (reload/stop, desktop
//  toggle). Programmatic UIKit. Every action is real and handled by the browser via `BrowserMenuDelegate`.
//

import UIKit

/// The actions the menu can emit. The browser controller performs them.
enum BrowserMenuAction {
    case reloadOrStop
    case share
    case copyLink
    case findOnPage
    case toggleDesktopSite
    case fullPageScreenshot
    case userscripts
    case extensions
    case installUserscript
    case toggleBookmark
    case bookmarks
    case addToReadingList
    case readingList
    case history
    case downloads
    case settings
    case proxy
    case reader
    case translatePage
    case zoom
}

/// A snapshot of the active tab the menu renders against.
struct BrowserMenuState {
    var title: String?
    var host: String?
    var isLoading: Bool
    var isDesktopSite: Bool
    var canInteractWithPage: Bool   // a real page is loaded (share/copy/find/desktop apply)
    var canInstallUserscript: Bool  // the current URL is a *.user.js
    var isBookmarked: Bool = false  // the current URL is already bookmarked
    var zoomPercent: Int = 100      // active tab's page-zoom level, for the zoom stepper
    var matchedScripts: [MenuScript] = []  // userscripts whose @match/@include matched this page
    var extensionActions: [MenuExtensionAction] = []  // enabled extensions' chrome.action entries
    var scriptCommands: [MenuScriptCommand] = []  // GM_registerMenuCommand entries for the active tab
    var proxySupported: Bool = false   // the per-WebView proxy API exists (iOS 17+)
    var proxyEnabled: Bool = false     // a proxy is currently applied to browsing
    var proxyHasActive: Bool = false   // a proxy is selected (so the toggle can be turned on)
    var proxyName: String?             // the active proxy's display name, for the row subtitle
}

/// A userscript matching the active page, rendered in the menu's "On this page" section.
struct MenuScript {
    let id: UUID
    let name: String
    let iconURL: String?
    let enabled: Bool
}

/// An enabled extension's chrome.action, rendered in the menu's "Extensions" section. Tapping it
/// opens the extension's popup (if any) or fires chrome.action.onClicked into its background worker.
struct MenuExtensionAction {
    let extensionID: String
    let title: String
    let badgeText: String
    let badgeColor: UIColor
    let badgeTextColor: UIColor
    let iconPath: String?   // action-resolved icon (honours runtime setIcon); nil = none chosen
    var fallbackIconPath: String?  // the static manifest icon (action default_icon → top-level icons),
                                   // tried when iconPath is nil or its file can't be loaded, so the row
                                   // shows the same real icon the dashboard list does — not the glyph
    var hasPopup: Bool = false     // the action declares a default_popup
    var hasOptions: Bool = false   // the manifest declares an options page
}

/// A GM_registerMenuCommand entry for a userscript matching the active tab, rendered in the menu's
/// "Script commands" section. `token`/`commandID` are the opaque native handle used to fire it back.
struct MenuScriptCommand {
    let token: String
    let commandID: String
    let title: String
    let scriptName: String
    let accessKey: String?
    let autoClose: Bool
}

@MainActor
protocol BrowserMenuDelegate: AnyObject {
    func browserMenu(_ menu: BrowserMenuViewController, didSelect action: BrowserMenuAction)
    func browserMenu(_ menu: BrowserMenuViewController, didToggleScript id: UUID, enabled: Bool)
    func browserMenu(_ menu: BrowserMenuViewController, didToggleProxy enabled: Bool)
    func browserMenu(_ menu: BrowserMenuViewController, didTapExtensionAction extensionID: String)
    func browserMenu(_ menu: BrowserMenuViewController, didTapScriptCommand command: MenuScriptCommand)
    /// Long-press affordance on an extension row: open its options page (popup uses didTapExtensionAction).
    func browserMenu(_ menu: BrowserMenuViewController, didRequestExtensionOptions extensionID: String)
}

@MainActor
final class BrowserMenuViewController: UIViewController {

    private let state: BrowserMenuState
    private weak var delegate: BrowserMenuDelegate?

    init(state: BrowserMenuState, delegate: BrowserMenuDelegate) {
        self.state = state
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
        buildLayout()
    }

    /// Wrap for presentation as a bottom sheet with a grabber.
    func wrappedForPresentation() -> UIViewController {
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        return self
    }

    // MARK: - Layout

    private func buildLayout() {
        // A scroll view so the menu never clips: with the "On this page" section the content can
        // exceed even the .large detent on smaller iPhones, and the lower rows must stay reachable.
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(root)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            root.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            root.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16)
        ])

        root.addArrangedSubview(makeHeader())
        // New-tab / private-tab live on the toolbar + button (tap / long-press) and the tab grid, not
        // here — so the tile row shows only page actions, and only when there's a page to act on.
        if state.canInteractWithPage {
            root.addArrangedSubview(makeTileRow())
        }
        if !state.matchedScripts.isEmpty {
            root.addArrangedSubview(makeScriptsSection())
        }
        if !state.scriptCommands.isEmpty {
            root.addArrangedSubview(makeScriptCommandsSection())
        }
        if !state.extensionActions.isEmpty {
            root.addArrangedSubview(makeExtensionsSection())
        }
        // Userscripts & Extensions are the headline features — keep them prominent in a Library
        // section near the top, not buried beneath the page actions.
        root.addArrangedSubview(makeLibrarySection())
        root.addArrangedSubview(makeActionList())
    }

    private func makeHeader() -> UIView {
        let title = UILabel()
        title.text = state.title?.isEmpty == false ? state.title : (state.host ?? "New Tab")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = BrownBearTheme.Palette.textPrimary
        title.numberOfLines = 1

        let subtitle = UILabel()
        subtitle.text = state.host
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = BrownBearTheme.Palette.textSecondary
        subtitle.numberOfLines = 1
        subtitle.isHidden = (state.host == nil)

        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }

    /// Primary page actions (only shown when a page is loaded — see buildLayout).
    private func makeTileRow() -> UIView {
        let tiles: [UIView] = [
            makeTile(icon: "square.and.arrow.up", title: "Share", action: .share),
            makeTile(icon: "magnifyingglass", title: "Find", action: .findOnPage),
            makeTile(icon: state.isDesktopSite ? "iphone" : "desktopcomputer",
                     title: state.isDesktopSite ? "Mobile" : "Desktop",
                     action: .toggleDesktopSite,
                     highlighted: state.isDesktopSite)
        ]
        let row = UIStackView(arrangedSubviews: tiles)
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        return row
    }

    /// The page-action card (reload/stop, bookmark this page, copy link, install). Library
    /// destinations live in their own prominent section — see makeLibrarySection.
    private func makeActionList() -> UIView {
        var rows: [UIView] = []
        if state.canInteractWithPage {
            rows.append(makeRow(icon: state.isLoading ? "xmark" : "arrow.clockwise",
                                title: state.isLoading ? "Stop" : "Reload", action: .reloadOrStop))
            rows.append(makeRow(icon: state.isBookmarked ? "star.fill" : "star",
                                title: state.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                                action: .toggleBookmark))
            rows.append(makeRow(icon: "eyeglasses", title: "Add to Reading List", action: .addToReadingList))
            rows.append(makeRow(icon: "link", title: "Copy Link", action: .copyLink))
            rows.append(makeRow(icon: "doc.plaintext", title: "Reader", action: .reader))
            rows.append(makeRow(icon: "character.bubble", title: "Translate Page", action: .translatePage))
            rows.append(makeRow(icon: "rectangle.dashed", title: "Full Page Screenshot",
                                action: .fullPageScreenshot))
            rows.append(makeRow(icon: "textformat.size", title: "Zoom (\(state.zoomPercent)%)", action: .zoom))
        }
        if state.canInstallUserscript {
            rows.append(makeRow(icon: "arrow.down.doc", title: "Install this userscript", action: .installUserscript))
        }
        guard !rows.isEmpty else { return UIView() }   // a fresh tab has no page actions
        return cardContainer(rows: rows)
    }

    /// Userscripts, Extensions, and Bookmarks — BrownBear's headline surfaces — kept prominent in a
    /// "Library" section near the top of the menu rather than buried beneath the page actions.
    private func makeLibrarySection() -> UIView {
        let header = UILabel()
        header.text = "Library"
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = BrownBearTheme.Palette.textSecondary
        let card = cardContainer(rows: [
            makeRow(icon: "scroll", title: "Userscripts", action: .userscripts),
            makeRow(icon: "puzzlepiece.extension", title: "Extensions", action: .extensions),
            makeRow(icon: "bookmark", title: "Bookmarks", action: .bookmarks),
            makeRow(icon: "eyeglasses", title: "Reading List", action: .readingList),
            makeRow(icon: "clock.arrow.circlepath", title: "History", action: .history),
            makeRow(icon: "arrow.down.circle", title: "Downloads", action: .downloads),
            makeProxyRow(),
            makeRow(icon: "gearshape", title: "Settings", action: .settings)
        ])
        let section = UIStackView(arrangedSubviews: [header, card])
        section.axis = .vertical
        section.spacing = 8
        return section
    }

    /// A rounded card wrapping a vertical list of rows with hairline separators.
    private func cardContainer(rows: [UIView]) -> UIView {
        let container = UIView()
        container.backgroundColor = BrownBearTheme.Palette.cell
        container.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        container.layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: interleaveSeparators(rows))
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }

    private func interleaveSeparators(_ rows: [UIView]) -> [UIView] {
        var out: [UIView] = []
        for (index, row) in rows.enumerated() {
            out.append(row)
            if index < rows.count - 1 {
                let line = UIView()
                line.backgroundColor = BrownBearTheme.Palette.separator
                line.translatesAutoresizingMaskIntoConstraints = false
                line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                let inset = UIView()
                inset.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 52),
                    line.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
                    line.topAnchor.constraint(equalTo: inset.topAnchor),
                    line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
                    inset.heightAnchor.constraint(equalToConstant: 0.5)
                ])
                out.append(inset)
            }
        }
        return out
    }

    /// "On this page": the userscripts matching the active URL, each with its @icon and an inline
    /// enable toggle (re-injection happens on the next navigation, matching the engine's behavior).
    private func makeScriptsSection() -> UIView {
        let header = UILabel()
        header.text = "On this page"
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = BrownBearTheme.Palette.textSecondary

        let card = UIView()
        card.backgroundColor = BrownBearTheme.Palette.cell
        card.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        card.layer.cornerCurve = .continuous

        let rows = state.matchedScripts.map { makeScriptRow($0) }
        let stack = UIStackView(arrangedSubviews: interleaveSeparators(rows))
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])

        let section = UIStackView(arrangedSubviews: [header, card])
        section.axis = .vertical
        section.spacing = 8
        return section
    }

    private func makeScriptRow(_ script: MenuScript) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "scroll"))
        icon.tintColor = BrownBearTheme.Palette.accent
        icon.contentMode = .scaleAspectFit
        icon.backgroundColor = BrownBearTheme.Palette.accent.withAlphaComponent(0.14)
        icon.layer.cornerRadius = 7
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28),
                                     icon.heightAnchor.constraint(equalToConstant: 28)])
        if let iconURL = script.iconURL {
            Task { @MainActor in
                if let image = await ScriptIconLoader.shared.icon(forURLString: iconURL) {
                    icon.image = image
                    icon.contentMode = .scaleAspectFill
                }
            }
        }

        let name = UILabel()
        name.text = script.name
        name.font = .systemFont(ofSize: 15)
        name.textColor = BrownBearTheme.Palette.textPrimary
        name.numberOfLines = 1

        let toggle = UISwitch()
        toggle.isOn = script.enabled
        toggle.onTintColor = BrownBearTheme.Palette.accent
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        let id = script.id
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            self.delegate?.browserMenu(self, didToggleScript: id, enabled: toggle.isOn)
        }, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [icon, name, toggle])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        return row
    }


    // MARK: - Script commands (GM_registerMenuCommand)

    /// "Script commands": each GM_registerMenuCommand a matching userscript registered for this tab.
    /// Tapping fires the script's callback back into its own frame/world; autoClose controls dismissal.
    private func makeScriptCommandsSection() -> UIView {
        let header = UILabel()
        header.text = "Script commands"
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = BrownBearTheme.Palette.textSecondary

        let card = UIView()
        card.backgroundColor = BrownBearTheme.Palette.cell
        card.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        card.layer.cornerCurve = .continuous

        let rows = state.scriptCommands.map { makeScriptCommandRow($0) }
        let stack = UIStackView(arrangedSubviews: interleaveSeparators(rows))
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])

        let section = UIStackView(arrangedSubviews: [header, card])
        section.axis = .vertical
        section.spacing = 8
        return section
    }

    private func makeScriptCommandRow(_ command: MenuScriptCommand) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "terminal"))
        icon.tintColor = BrownBearTheme.Palette.accent
        icon.contentMode = .scaleAspectFit
        icon.backgroundColor = BrownBearTheme.Palette.accent.withAlphaComponent(0.14)
        icon.layer.cornerRadius = 7
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28),
                                     icon.heightAnchor.constraint(equalToConstant: 28)])

        let title = UILabel()
        title.text = command.title
        title.font = .systemFont(ofSize: 15)
        title.textColor = BrownBearTheme.Palette.textPrimary
        title.numberOfLines = 1

        // The accessKey is shown as a trailing hint — iOS menus have no keyboard accelerators, so it's
        // informational (parity with desktop GM, where it's the underlined mnemonic).
        var arranged: [UIView] = [icon, title]
        if let key = command.accessKey, !key.isEmpty {
            let hint = UILabel()
            hint.text = key.uppercased()
            hint.font = .systemFont(ofSize: 13, weight: .semibold)
            hint.textColor = BrownBearTheme.Palette.textSecondary
            hint.setContentHuggingPriority(.required, for: .horizontal)
            arranged.append(hint)
        }

        let row = UIStackView(arrangedSubviews: arranged)
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        row.isUserInteractionEnabled = true

        let button = UIButton(type: .system)
        button.addAction(UIAction { [weak self] _ in self?.tapScriptCommand(command) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }

    /// Fire a script command. autoClose=false keeps the menu open (a command that toggles UI state),
    /// matching desktop GM; otherwise dismiss first, then deliver.
    private func tapScriptCommand(_ command: MenuScriptCommand) {
        if command.autoClose {
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.delegate?.browserMenu(self, didTapScriptCommand: command)
            }
        } else {
            delegate?.browserMenu(self, didTapScriptCommand: command)
        }
    }

    // MARK: - Extensions (chrome.action)

    /// iOS has no extension toolbar, so each enabled extension's chrome.action is surfaced as a row in
    /// the menu. Tapping a row opens the extension's popup (if any) or fires chrome.action.onClicked.
    private func makeExtensionsSection() -> UIView {
        let header = UILabel()
        header.text = "Extensions"
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = BrownBearTheme.Palette.textSecondary

        let card = UIView()
        card.backgroundColor = BrownBearTheme.Palette.cell
        card.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        card.layer.cornerCurve = .continuous

        let rows = state.extensionActions.map { makeExtensionActionRow($0) }
        let stack = UIStackView(arrangedSubviews: interleaveSeparators(rows))
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])

        let section = UIStackView(arrangedSubviews: [header, card])
        section.axis = .vertical
        section.spacing = 8
        return section
    }

    private func makeExtensionActionRow(_ action: MenuExtensionAction) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "puzzlepiece.extension.fill"))
        icon.tintColor = BrownBearTheme.Palette.accent
        icon.contentMode = .scaleAspectFit
        icon.backgroundColor = BrownBearTheme.Palette.accent.withAlphaComponent(0.14)
        icon.layer.cornerRadius = 7
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28),
                                     icon.heightAnchor.constraint(equalToConstant: 28)])
        // Load the extension's own icon from its package. Try the action-resolved path first (honours a
        // runtime setIcon), then the static manifest icon — the exact path the dashboard list loads — so a
        // stale/absent action icon falls back to the real branded icon here too, not the puzzle glyph.
        var candidatePaths: [String] = []
        for path in [action.iconPath, action.fallbackIconPath] {
            if let path, !path.isEmpty, !candidatePaths.contains(path) { candidatePaths.append(path) }
        }
        if !candidatePaths.isEmpty {
            let extensionID = action.extensionID
            Task { @MainActor in
                for path in candidatePaths {
                    if let data = await BrownBearServices.shared.webExtensionStore.file(extensionID: extensionID, path: path),
                       let image = UIImage(data: data) {
                        icon.image = image
                        icon.contentMode = .scaleAspectFit
                        icon.backgroundColor = .clear
                        break
                    }
                }
            }
        }

        let name = UILabel()
        name.text = action.title
        name.font = .systemFont(ofSize: 15)
        name.textColor = BrownBearTheme.Palette.textPrimary
        name.numberOfLines = 1

        // Reserve trailing room for the "•••" menu button when there are secondary actions, so the
        // full-row tap button below doesn't sit under it.
        let showsMenuButton = action.hasPopup || action.hasOptions
        var arranged: [UIView] = action.badgeText.isEmpty
            ? [icon, name]
            : [icon, name, makeBadgePill(text: action.badgeText, color: action.badgeColor, textColor: action.badgeTextColor)]
        if showsMenuButton {
            let spacer = UIView()
            spacer.widthAnchor.constraint(equalToConstant: 36).isActive = true
            spacer.setContentHuggingPriority(.required, for: .horizontal)
            arranged.append(spacer)
        }
        let row = UIStackView(arrangedSubviews: arranged)
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        row.isUserInteractionEnabled = true

        // Tapping the row body opens the popup (or fires chrome.action.onClicked) — the primary action.
        let button = UIButton(type: .system)
        button.addAction(UIAction { [weak self] _ in self?.tapExtensionAction(action.extensionID) }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        // A tappable "•••" that presents a menu (Open Popup / Options) — iOS has no toolbar to
        // right-click. Added ON TOP of the row button and pinned trailing, so a tap here shows the menu
        // while a tap anywhere else still opens the popup. showsMenuAsPrimaryAction = a single tap.
        if showsMenuButton {
            let menuButton = UIButton(type: .system)
            menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            menuButton.tintColor = BrownBearTheme.Palette.textSecondary
            menuButton.showsMenuAsPrimaryAction = true
            menuButton.menu = extensionMenu(for: action)
            menuButton.accessibilityLabel = "More actions for \(action.title)"
            menuButton.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(menuButton)
            NSLayoutConstraint.activate([
                menuButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                menuButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                menuButton.widthAnchor.constraint(equalToConstant: 36),
                menuButton.heightAnchor.constraint(equalToConstant: 36)
            ])
        }
        return row
    }

    /// The "•••" menu for an extension row: Open Popup / Options, per what the manifest declares.
    private func extensionMenu(for action: MenuExtensionAction) -> UIMenu {
        var items: [UIAction] = []
        if action.hasPopup {
            items.append(UIAction(title: "Open Popup", image: UIImage(systemName: "macwindow")) { [weak self] _ in
                self?.tapExtensionAction(action.extensionID)
            })
        }
        if action.hasOptions {
            items.append(UIAction(title: "Options", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.requestExtensionOptions(action.extensionID)
            })
        }
        return UIMenu(title: action.title, children: items)
    }

    private func requestExtensionOptions(_ extensionID: String) {
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.delegate?.browserMenu(self, didRequestExtensionOptions: extensionID)
        }
    }

    /// A small badge pill (chrome.action.setBadgeText/Color) shown trailing an extension row.
    private func makeBadgePill(text: String, color: UIColor, textColor: UIColor) -> UIView {
        let label = PaddedLabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = textColor
        label.backgroundColor = color
        label.layer.cornerRadius = 8
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func tapExtensionAction(_ extensionID: String) {
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.delegate?.browserMenu(self, didTapExtensionAction: extensionID)
        }
    }

    // MARK: - Components

    private func makeTile(icon: String, title: String, action: BrowserMenuAction, highlighted: Bool = false) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        config.imagePlacement = .top
        config.imagePadding = 8
        config.cornerStyle = .large
        config.baseBackgroundColor = highlighted ? BrownBearTheme.Palette.accent.withAlphaComponent(0.18) : BrownBearTheme.Palette.cell
        config.baseForegroundColor = highlighted ? BrownBearTheme.Palette.accent : BrownBearTheme.Palette.textPrimary
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 8, bottom: 12, trailing: 8)
        var titleAttr = AttributeContainer()
        titleAttr.font = .systemFont(ofSize: 12, weight: .medium)
        config.attributedTitle = AttributedString(title, attributes: titleAttr)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.select(action) })
        return button
    }

    private func makeRow(icon: String, title: String, action: BrowserMenuAction) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: icon)
        config.imagePadding = 16
        config.baseForegroundColor = BrownBearTheme.Palette.textPrimary
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.select(action) })
        button.contentHorizontalAlignment = .leading
        button.tintColor = BrownBearTheme.Palette.accent
        return button
    }

    private func select(_ action: BrowserMenuAction) {
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.delegate?.browserMenu(self, didSelect: action)
        }
    }
}

private extension BrowserMenuViewController {
    /// The Library "Proxy" row: tapping the body opens the proxy config (a quick door from the browser),
    /// while the trailing switch flips the active proxy on/off in place. The switch is enabled only when a
    /// proxy is selected on iOS 17+; the subtitle reflects the current state. (In an extension so the main
    /// view-controller body stays under the type-body length limit.)
    func makeProxyRow() -> UIView {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "network")
        config.imagePadding = 16
        config.title = "Proxy"
        if !state.proxySupported {
            config.subtitle = "Requires iOS 17 or later"
        } else if state.proxyEnabled, let name = state.proxyName {
            config.subtitle = "On · \(name)"
        } else if state.proxyHasActive {
            config.subtitle = "Off · tap to manage"
        } else {
            config.subtitle = "Off · tap to set up"
        }
        config.baseForegroundColor = BrownBearTheme.Palette.textPrimary
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 8)
        let button = UIButton(configuration: config,
                              primaryAction: UIAction { [weak self] _ in self?.select(.proxy) })
        button.contentHorizontalAlignment = .leading
        button.tintColor = BrownBearTheme.Palette.accent
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toggle = UISwitch()
        toggle.isOn = state.proxyEnabled
        toggle.onTintColor = BrownBearTheme.Palette.accent
        toggle.isEnabled = state.proxySupported && state.proxyHasActive
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            self.delegate?.browserMenu(self, didToggleProxy: toggle.isOn)
        }, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [button, toggle])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 16)
        return row
    }
}

/// A UILabel with horizontal padding, used for the small chrome.action badge pill.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}

