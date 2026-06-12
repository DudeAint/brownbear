//
//  ExtensionsListPopoverViewController.swift
//  BrownBear
//
//  The glassy popover shown when the pinned toolbar extensions button is tapped and MORE THAN ONE
//  extension is installed: a compact frosted list of the enabled extensions (icon + name), each row
//  opening that extension's action. With a single extension the browser skips this and opens its popup
//  directly. Mirrors the Site Shields popover (frosted glass, arrow-anchored, stays a popover on
//  compact widths) so the whole extensions surface feels of a piece.
//

import UIKit

/// One enabled extension shown in the list (its icon already resolved from the package by the browser),
/// plus its live action badge and which surfaces it offers (so the row's hold-menu shows only the ones
/// that apply).
struct ExtensionListItem {
    let id: String
    let name: String
    let icon: UIImage?
    var badge: String? = nil
    var badgeBackground: UIColor? = nil
    var badgeForeground: UIColor? = nil
    var hasPopup: Bool = false
    var hasOptions: Bool = false
    var hasSidebar: Bool = false
}

@MainActor
final class ExtensionsListPopoverViewController: UIViewController {

    /// A hold-menu action on an extension row, handled by the browser.
    enum RowAction { case popup, options, sidebar, manage, uninstall }

    private let items: [ExtensionListItem]
    private let onSelect: (String) -> Void
    private let onAction: (RowAction, ExtensionListItem) -> Void
    private let onUnpin: () -> Void
    private static let rowHeight: CGFloat = 52
    /// Cap the popover height; past this the rows scroll inside it (the title stays pinned at the top).
    private static let maxHeight: CGFloat = 420

    init(items: [ExtensionListItem],
         onSelect: @escaping (String) -> Void,
         onAction: @escaping (RowAction, ExtensionListItem) -> Void,
         onUnpin: @escaping () -> Void) {
        self.items = items
        self.onSelect = onSelect
        self.onAction = onAction
        self.onUnpin = onUnpin
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        GlassBackground.install(in: view)
        buildLayout()
    }

    /// Present arrow-anchored to `sourceView` (the toolbar extensions button), rising up over the page.
    func makePopover(sourceView: UIView, sourceRect: CGRect) -> UIViewController {
        modalPresentationStyle = .popover
        preferredContentSize = CGSize(width: 280, height: preferredHeight())
        if let popover = popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.down, .up]   // the toolbar is at the bottom
            popover.delegate = self
            popover.backgroundColor = .clear                  // let the glass backdrop show
        }
        return self
    }

    private func preferredHeight() -> CGFloat {
        let header: CGFloat = 40   // title + its spacing
        // +1 row for the trailing "Unpin from toolbar" action, + its separator.
        let content = header + CGFloat(items.count + 1) * Self.rowHeight + 14 + 9
        return min(content, Self.maxHeight)   // taller than this → the rows scroll
    }

    // MARK: - Layout

    private func buildLayout() {
        // The title is pinned at the top (never scrolls off); the rows live in a scroll view below it so
        // a long extension list scrolls instead of pushing the title off the popover.
        let title = UILabel()
        title.text = "Extensions"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = BrownBearTheme.Palette.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        view.addSubview(scroll)

        var rows: [UIView] = items.map(makeRow)
        // A hairline, then the trailing "Unpin from toolbar" action (Chrome's "remove from toolbar").
        let separator = UIView()
        separator.backgroundColor = BrownBearTheme.Palette.borderSubtle
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rows.append(separator)
        rows.append(makeUnpinRow())

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let guide = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    private func makeRow(_ item: ExtensionListItem) -> UIView {
        let icon = UIImageView(image: item.icon ?? UIImage(systemName: "puzzlepiece.extension.fill"))
        icon.contentMode = .scaleAspectFit
        icon.tintColor = BrownBearTheme.Palette.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.layer.cornerRadius = 6
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 26),
                                     icon.heightAnchor.constraint(equalToConstant: 26)])

        let name = UILabel()
        name.text = item.name
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        name.textColor = BrownBearTheme.Palette.textPrimary
        name.numberOfLines = 1
        name.lineBreakMode = .byTruncatingTail

        let content = UIStackView(arrangedSubviews: [icon, name])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 12
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        button.addSubview(content)
        let id = item.id
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: true) { self.onSelect(id) }
        }, for: .touchUpInside)
        // Hold → the per-extension menu (open popup/options/side panel · Manage Extensions · Uninstall).
        // The button's tag indexes back to `items` so the delegate knows which extension this row is.
        button.tag = items.firstIndex { $0.id == item.id } ?? 0
        button.addInteraction(UIContextMenuInteraction(delegate: self))

        let constraints: [NSLayoutConstraint] = [
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ]
        NSLayoutConstraint.activate(constraints)

        // The live chrome.action badge, as a small pill on the trailing edge (matches the overflow menu).
        if let badgeText = item.badge, !badgeText.isEmpty {
            let badge = makeBadgePill(badgeText, background: item.badgeBackground, foreground: item.badgeForeground)
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
                badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                content.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8)
            ])
        } else {
            content.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -14).isActive = true
        }
        return button
    }

    /// The trailing "Unpin from Toolbar" action row (Chrome's "remove from toolbar").
    private func makeUnpinRow() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "pin.slash"))
        icon.contentMode = .scaleAspectFit
        icon.tintColor = BrownBearTheme.Palette.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 26),
                                     icon.heightAnchor.constraint(equalToConstant: 26)])
        let label = UILabel()
        label.text = "Unpin from Toolbar"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = BrownBearTheme.Palette.textSecondary

        let content = UIStackView(arrangedSubviews: [icon, label])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 12
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 10
        button.layer.cornerCurve = .continuous
        button.addSubview(content)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: true) { self.onUnpin() }
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -14),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }

    /// A small rounded badge pill carrying the extension's chrome.action badge text.
    private func makeBadgePill(_ text: String, background: UIColor?, foreground: UIColor?) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = foreground ?? BrownBearTheme.Palette.onAccent
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = UIView()
        pill.backgroundColor = background ?? BrownBearTheme.Palette.accent
        pill.layer.cornerRadius = 9
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 18),
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }

    /// The hold-menu for one extension row: open surfaces it offers, then Manage, then Uninstall.
    private func menu(for item: ExtensionListItem) -> UIMenu {
        var open: [UIMenuElement] = []
        if item.hasPopup {
            open.append(UIAction(title: "Open Popup", image: UIImage(systemName: "macwindow")) { [weak self] _ in self?.act(.popup, item) })
        }
        if item.hasOptions {
            open.append(UIAction(title: "Options", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.act(.options, item) })
        }
        if item.hasSidebar {
            open.append(UIAction(title: "Side Panel", image: UIImage(systemName: "sidebar.right")) { [weak self] _ in self?.act(.sidebar, item) })
        }
        let manage = UIAction(title: "Manage Extensions", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.act(.manage, item) }
        let uninstall = UIAction(title: "Uninstall \(item.name)", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.act(.uninstall, item) }
        // Inline sections so Manage sits right above Uninstall, both below the open actions.
        var sections: [UIMenuElement] = []
        if !open.isEmpty { sections.append(UIMenu(options: .displayInline, children: open)) }
        sections.append(UIMenu(options: .displayInline, children: [manage]))
        sections.append(UIMenu(options: .displayInline, children: [uninstall]))
        return UIMenu(children: sections)
    }

    private func act(_ action: RowAction, _ item: ExtensionListItem) {
        dismiss(animated: true) { self.onAction(action, item) }
    }
}

// MARK: - UIContextMenuInteractionDelegate (per-row hold menu)

extension ExtensionsListPopoverViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let tag = interaction.view?.tag, items.indices.contains(tag) else { return nil }
        let item = items[tag]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: item)
        }
    }
}

// MARK: - UIPopoverPresentationControllerDelegate (stay a true popover on iPhone)

extension ExtensionsListPopoverViewController: UIPopoverPresentationControllerDelegate {
    nonisolated func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
