//
//  OmniboxSuggestionsView.swift
//  BrownBear
//
//  The dropdown shown beneath the omnibox while editing. Rather than an opaque panel that fills the
//  whole page (which painted a flat white slab below the last row), it floats as a frosted GLASS CARD
//  that hugs its content: only as tall as the rows need, with the page staying visible beneath it.
//  Tapping that exposed page area dismisses the keyboard (Safari-style), so an accidental focus is one
//  tap to undo. The card springs in/out and grows/shrinks smoothly as the suggestion count changes.
//

import UIKit

@MainActor
protocol OmniboxSuggestionsViewDelegate: AnyObject {
    func suggestionsView(_ view: OmniboxSuggestionsView, didSelect suggestion: OmniboxSuggestion)
    /// The user tapped the exposed page area below/around the card — dismiss the keyboard.
    func suggestionsViewDidRequestDismiss(_ view: OmniboxSuggestionsView)
}

final class OmniboxSuggestionsView: UIView {

    weak var delegate: OmniboxSuggestionsViewDelegate?

    /// The floating card (shadow + rounded corners); `clip` rounds/clips the glass + table inside it.
    private let card = UIView()
    private let clip = UIView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var cardHeight: NSLayoutConstraint!

    private var suggestions: [OmniboxSuggestion] = []
    private static let cellID = "OmniboxSuggestionCell"
    private static let rowHeight: CGFloat = 58
    private static let cardRadius = BrownBearTheme.Metrics.cellCornerRadius

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The container fills the area beneath the bar but is itself transparent — the page shows through
        // everywhere the card doesn't cover, and a tap there dismisses the keyboard.
        backgroundColor = .clear
        isHidden = true

        let inset = BrownBearTheme.Metrics.chromeHorizontalInset

        // Card: carries the soft elevation shadow; not clipped so the shadow can spread.
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .clear
        card.layer.cornerRadius = Self.cardRadius
        card.layer.cornerCurve = .continuous
        addSubview(card)

        // Clip: rounds + clips the frosted glass and the table to the card's corners, with a hairline edge.
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.layer.cornerRadius = Self.cardRadius
        clip.layer.cornerCurve = .continuous
        clip.clipsToBounds = true
        clip.layer.borderWidth = BrownBearTheme.Metrics.hairline
        card.addSubview(clip)
        GlassBackground.install(in: clip, cornerRadius: Self.cardRadius)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = BrownBearTheme.Palette.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 0)
        tableView.rowHeight = Self.rowHeight
        tableView.keyboardDismissMode = .onDrag
        tableView.alwaysBounceVertical = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(tableView)

        cardHeight = card.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        cardHeight.priority = .defaultHigh   // yields to the "never taller than the available area" cap below
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            cardHeight,
            clip.topAnchor.constraint(equalTo: card.topAnchor),
            clip.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            tableView.topAnchor.constraint(equalTo: clip.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: clip.bottomAnchor)
        ])

        // Tap the exposed page area (anywhere outside the card) → dismiss the keyboard.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)

        applyChromeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The shadow path follows the card's rounded rect; refreshed whenever the card resizes.
    override func layoutSubviews() {
        super.layoutSubviews()
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: Self.cardRadius).cgPath
    }

    // Re-resolve the shadow opacity + hairline (CGColors don't follow trait/theme changes on their own).
    // A theme-family switch posts a trait nudge, so this also covers Clean↔OG at the same light/dark.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyChromeColors()
    }

    private func applyChromeColors() {
        BrownBearTheme.Elevation.level2.apply(to: card.layer, traits: traitCollection)
        clip.layer.borderColor = BrownBearTheme.Palette.borderSubtle.resolvedColor(with: traitCollection).cgColor
        tableView.separatorColor = BrownBearTheme.Palette.separator
    }

    /// Replace the displayed suggestions. The card springs in when it first appears, cross-fades its rows
    /// (and smoothly resizes) when already visible, and fades out keeping its rows when emptied.
    func update(_ suggestions: [OmniboxSuggestion]) {
        guard !suggestions.isEmpty else {
            animateOut()
            return
        }
        let wasHidden = isHidden
        self.suggestions = suggestions
        cardHeight.constant = CGFloat(suggestions.count) * Self.rowHeight
        if wasHidden {
            tableView.reloadData()
            tableView.setContentOffset(.zero, animated: false)
            animateIn()
        } else {
            tableView.setContentOffset(.zero, animated: false)
            UIView.transition(with: tableView, duration: 0.18, options: .transitionCrossDissolve) {
                self.tableView.reloadData()
            }
            // Grow/shrink the card to the new row count in step with the cross-fade — no jump.
            UIView.animate(withDuration: BrownBearTheme.Motion.sheetSpringDuration, delay: 0,
                           usingSpringWithDamping: BrownBearTheme.Motion.sheetSpringDamping, initialSpringVelocity: 0.3,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layoutIfNeeded()
            }
        }
    }

    /// Clear and hide the panel (called when editing ends).
    func dismiss() {
        update([])
    }

    /// Spring the card in from a slightly-raised, faded, fractionally-smaller state — a soft glassy
    /// settle that reads as the card materializing under the bar, not a hard cut.
    private func animateIn() {
        isHidden = false
        alpha = 1   // container (and its tap-to-dismiss zone) is live immediately
        card.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.97, y: 0.97)
        layoutIfNeeded()
        UIView.animate(withDuration: BrownBearTheme.Motion.sheetSpringDuration, delay: 0,
                       usingSpringWithDamping: BrownBearTheme.Motion.sheetSpringDamping, initialSpringVelocity: 0.45,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.card.alpha = 1
            self.card.transform = .identity
        }
    }

    /// Fade the card out (keeping its rows), drifting up a touch as it shrinks, then hide and clear — so
    /// dismissal reads as the glass receding rather than the content blinking away.
    private func animateOut() {
        guard !isHidden else {
            suggestions = []
            tableView.reloadData()
            return
        }
        UIView.animate(withDuration: BrownBearTheme.Motion.quick, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.card.alpha = 0
            self.card.transform = CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.98, y: 0.98)
        } completion: { _ in
            self.isHidden = true
            self.card.alpha = 1
            self.card.transform = .identity
            self.suggestions = []
            self.tableView.reloadData()
        }
    }

    @objc private func handleBackgroundTap() {
        delegate?.suggestionsViewDidRequestDismiss(self)
    }
}

extension OmniboxSuggestionsView: UIGestureRecognizerDelegate {
    // Only treat taps in the EXPOSED page area as dismiss taps; taps on the card belong to the table.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !card.frame.contains(touch.location(in: self))
    }
}

extension OmniboxSuggestionsView: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        suggestions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let suggestion = suggestions[indexPath.row]

        var config = UIListContentConfiguration.subtitleCell()
        config.text = suggestion.title
        config.secondaryText = suggestion.subtitle
        config.image = UIImage(systemName: suggestion.iconName)
        config.imageProperties.tintColor = BrownBearTheme.Palette.textSecondary
        config.textProperties.color = BrownBearTheme.Palette.textPrimary
        config.textProperties.numberOfLines = 1
        config.secondaryTextProperties.color = BrownBearTheme.Palette.textSecondary
        config.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = config
        cell.backgroundColor = .clear

        let selected = UIView()
        selected.backgroundColor = BrownBearTheme.Palette.accent.withAlphaComponent(0.12)
        cell.selectedBackgroundView = selected
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        delegate?.suggestionsView(self, didSelect: suggestions[indexPath.row])
    }
}
