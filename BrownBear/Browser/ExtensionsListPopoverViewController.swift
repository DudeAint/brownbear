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

/// One enabled extension shown in the list (its icon already resolved from the package by the browser).
struct ExtensionListItem {
    let id: String
    let name: String
    let icon: UIImage?
}

@MainActor
final class ExtensionsListPopoverViewController: UIViewController {

    private let items: [ExtensionListItem]
    private let onSelect: (String) -> Void
    private static let rowHeight: CGFloat = 52
    /// Cap the popover height; past this the rows scroll inside it (the title stays pinned at the top).
    private static let maxHeight: CGFloat = 360

    init(items: [ExtensionListItem], onSelect: @escaping (String) -> Void) {
        self.items = items
        self.onSelect = onSelect
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
        let content = header + CGFloat(items.count) * Self.rowHeight + 14
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

        let stack = UIStackView(arrangedSubviews: items.map(makeRow))
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

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -14),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
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
