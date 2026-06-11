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
        let header: CGFloat = 38
        let rows = CGFloat(items.count) * Self.rowHeight
        return header + rows + 18   // header + rows + bottom padding
    }

    // MARK: - Layout

    private func buildLayout() {
        let title = UILabel()
        title.text = "Extensions"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = BrownBearTheme.Palette.textSecondary

        let rows: [UIView] = [title] + items.map(makeRow)
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 2
        stack.setCustomSpacing(8, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -14)
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
