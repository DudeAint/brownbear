//
//  VerticalTabCell.swift
//  BrownBear
//
//  One row in the vertical-tabs side panel: favicon + title + a close button, Orion/Kagi style. The
//  active tab is tinted with the accent wash so it's obvious which tab you're on. Favicons load async
//  (TabFaviconLoader) with a per-configure token so a recycled cell can't paint a stale icon.
//

import UIKit

final class VerticalTabCell: UITableViewCell {

    static let reuseID = "VerticalTabCell"

    /// Called when the row's × is tapped. The panel closes that tab and refreshes the list.
    var onClose: (() -> Void)?

    private let faviconView = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let selectionWash = UIView()
    /// Bumped on every `configure`; an async favicon callback only applies if it still matches, so a
    /// recycled cell never shows the previous tab's icon.
    private var faviconToken = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        // Accent wash behind the whole row for the active tab — set up at zero alpha, shown in configure.
        selectionWash.backgroundColor = BrownBearTheme.Palette.accentSoft
        selectionWash.layer.cornerRadius = 10
        selectionWash.layer.cornerCurve = .continuous
        selectionWash.isHidden = true
        selectionWash.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(selectionWash)

        faviconView.contentMode = .scaleAspectFit
        faviconView.clipsToBounds = true
        faviconView.layer.cornerRadius = 4
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(faviconView)

        titleLabel.font = BrownBearTheme.Typography.bodyScaled()
        titleLabel.textColor = BrownBearTheme.Palette.textPrimary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let xConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
        closeButton.tintColor = BrownBearTheme.Palette.textSecondary
        closeButton.addTarget(self, action: #selector(tapClose), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            selectionWash.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            selectionWash.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            selectionWash.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            selectionWash.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            faviconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            faviconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 22),
            faviconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    /// Configure the row. `host` is nil for a tab still on the New Tab page (no navigation yet) — shown
    /// with a sparkle glyph, matching the panel's "Empty Tab" rows. `isActive` tints the whole row.
    func configure(title: String, host: String?, isActive: Bool, isNewTab: Bool) {
        // In edit (reorder/delete) mode the table shows its own delete control + reorder grip, so the
        // custom × is hidden to avoid two delete affordances on one row.
        closeButton.isHidden = isEditing
        titleLabel.text = title
        titleLabel.textColor = isActive ? BrownBearTheme.Palette.accent : BrownBearTheme.Palette.textPrimary
        titleLabel.font = isActive
            ? .systemFont(ofSize: 16, weight: .semibold)
            : BrownBearTheme.Typography.bodyScaled()
        selectionWash.isHidden = !isActive

        faviconToken += 1
        let token = faviconToken

        guard let host, !isNewTab else {
            // New Tab / no URL yet — a sparkle, like Orion's "Empty Tab".
            faviconView.image = UIImage(systemName: isNewTab ? "sparkles" : "globe")
            faviconView.tintColor = isNewTab
                ? BrownBearTheme.Palette.accent
                : BrownBearTheme.Palette.textTertiary
            return
        }

        if let cached = TabFaviconLoader.shared.cachedFavicon(forHost: host) {
            faviconView.image = cached
            faviconView.tintColor = nil
            return
        }
        // Placeholder while the real icon loads. The Task inherits the main actor (this is a @MainActor
        // cell), so the UI mutation is on the main actor; the token guards against cell reuse.
        faviconView.image = UIImage(systemName: "globe")
        faviconView.tintColor = BrownBearTheme.Palette.textTertiary
        Task { [weak self] in
            let image = await TabFaviconLoader.shared.favicon(forHost: host)
            guard let self, self.faviconToken == token, let image else { return }
            self.faviconView.image = image
            self.faviconView.tintColor = nil
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        closeButton.isHidden = editing   // hide the custom × while the table shows its edit controls
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconToken += 1            // invalidate any in-flight favicon load
        onClose = nil
        faviconView.image = nil
        selectionWash.isHidden = true
    }

    @objc private func tapClose() { onClose?() }
}
