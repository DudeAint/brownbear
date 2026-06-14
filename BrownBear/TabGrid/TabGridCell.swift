//
//  TabGridCell.swift
//  BrownBear
//
//  One card in the square tab grid: a page snapshot, the page title, and a close button. The
//  active tab is highlighted with an accent ring. Closing is reported via the `onClose` closure
//  so the controller can drive the model without the cell knowing about TabManager.
//

import UIKit

final class TabGridCell: UICollectionViewCell {

    static let reuseID = "TabGridCell"

    /// Invoked when the user taps the close (×) button.
    var onClose: (() -> Void)?

    private let card = UIView()
    private let snapshotView = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        snapshotView.image = nil
        snapshotView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        titleLabel.text = nil
        placeholderLabel.text = nil
        placeholderLabel.isHidden = true
        onClose = nil
        setActive(false)
    }

    // MARK: - Configuration

    func configure(title: String, snapshot: UIImage?, isActive: Bool) {
        titleLabel.text = title
        if let snapshot {
            snapshotView.image = snapshot
            placeholderLabel.isHidden = true
        } else {
            snapshotView.image = nil
            placeholderLabel.text = title
            placeholderLabel.isHidden = false
        }
        updateSnapshotAnchor()
        setActive(isActive)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSnapshotAnchor()
    }

    /// Show the TOP of the page in the card (Safari tab-card behaviour), not the vertical centre: a portrait
    /// page is much taller than the card's picture region, and centre-cropping it hides the title/header the
    /// user recognises. We fill the width and anchor to the top by mapping the top slice of the image to the
    /// view via `contentsRect` (so it stays undistorted — the slice shares the view's aspect). This also makes
    /// the open/close hero morph seamless: the card and the (top-anchored) page hero show the same content.
    private func updateSnapshotAnchor() {
        guard let image = snapshotView.image,
              snapshotView.bounds.width > 0, snapshotView.bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else {
            snapshotView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let viewAspect = snapshotView.bounds.width / snapshotView.bounds.height
        let imageAspect = image.size.width / image.size.height
        if imageAspect < viewAspect {
            // Image taller than the card region → fill width, anchor to the top.
            snapshotView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: imageAspect / viewAspect)
        } else {
            // Image wider → fill height, centre horizontally.
            let width = viewAspect / imageAspect
            snapshotView.layer.contentsRect = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
    }

    /// The on-screen (window) frame of the page-snapshot region — the picture area of the card, excluding
    /// the title strip — for the hero "card expands into the page" transition, which pairs it with the
    /// tab's own page snapshot. Nil for a placeholder card (no snapshot yet) or before it has a real size,
    /// so the transition falls back to its plain fade.
    func snapshotRegionFrame() -> CGRect? {
        guard snapshotView.image != nil else { return nil }
        let frame = snapshotView.convert(snapshotView.bounds, to: nil)
        return (frame.width > 1 && frame.height > 1) ? frame : nil
    }

    private func setActive(_ active: Bool) {
        card.layer.borderWidth = active ? 2.5 : BrownBearTheme.Metrics.hairline
        card.layer.borderColor = (active ? BrownBearTheme.Palette.accent
                                          : BrownBearTheme.Palette.separator).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Refresh CGColor-backed borders for the new appearance.
        let active = card.layer.borderWidth > 2
        setActive(active)
    }

    // MARK: - Build

    private func build() {
        contentView.backgroundColor = .clear

        card.backgroundColor = BrownBearTheme.Palette.cell
        card.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // scaleToFill + a top-anchored `contentsRect` (see updateSnapshotAnchor) shows the page's top
        // undistorted, rather than scaleAspectFill's centre crop.
        snapshotView.contentMode = .scaleToFill
        snapshotView.clipsToBounds = true
        snapshotView.backgroundColor = BrownBearTheme.Palette.background
        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(snapshotView)

        placeholderLabel.font = BrownBearTheme.Typography.tabTitle()
        placeholderLabel.textColor = BrownBearTheme.Palette.textSecondary
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 2
        placeholderLabel.isHidden = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.addSubview(placeholderLabel)

        let titleBar = UIView()
        titleBar.backgroundColor = BrownBearTheme.Palette.cell
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleBar)

        titleLabel.font = BrownBearTheme.Typography.tabTitle()
        titleLabel.textColor = BrownBearTheme.Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleLabel)

        let closeConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: closeConfig), for: .normal)
        closeButton.tintColor = BrownBearTheme.Palette.textPrimary
        closeButton.backgroundColor = BrownBearTheme.Palette.chrome.withAlphaComponent(0.9)
        closeButton.layer.cornerRadius = 12
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(tapClose), for: .touchUpInside)
        card.addSubview(closeButton)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            snapshotView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            snapshotView.topAnchor.constraint(equalTo: card.topAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: snapshotView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: snapshotView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: snapshotView.leadingAnchor, constant: 8),
            placeholderLabel.trailingAnchor.constraint(equalTo: snapshotView.trailingAnchor, constant: -8),

            titleBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: snapshotView.bottomAnchor),
            titleBar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @objc private func tapClose() { onClose?() }
}
