//
//  OmniboxSuggestionsView.swift
//  BrownBear
//
//  The dropdown shown beneath the omnibox while editing: a plain table of OmniboxSuggestion rows
//  (icon + title + host). The browser controller owns it, feeds it suggestions, and acts on taps.
//  Hidden whenever the list is empty so it never covers the page with a blank panel.
//

import UIKit

@MainActor
protocol OmniboxSuggestionsViewDelegate: AnyObject {
    func suggestionsView(_ view: OmniboxSuggestionsView, didSelect suggestion: OmniboxSuggestion)
}

final class OmniboxSuggestionsView: UIView {

    weak var delegate: OmniboxSuggestionsViewDelegate?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var suggestions: [OmniboxSuggestion] = []
    private static let cellID = "OmniboxSuggestionCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BrownBearTheme.Palette.background
        isHidden = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 0)
        tableView.rowHeight = 58
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replace the displayed suggestions. The panel springs in when it first appears, cross-fades its
    /// rows when already visible, and fades out (keeping its current rows) when emptied.
    func update(_ suggestions: [OmniboxSuggestion]) {
        guard !suggestions.isEmpty else {
            animateOut()
            return
        }
        let wasHidden = isHidden
        self.suggestions = suggestions
        if wasHidden {
            tableView.reloadData()
            tableView.setContentOffset(.zero, animated: false)
            animateIn()
        } else {
            tableView.setContentOffset(.zero, animated: false)
            UIView.transition(with: tableView, duration: 0.2, options: .transitionCrossDissolve) {
                self.tableView.reloadData()
            }
        }
    }

    /// Clear and hide the panel (called when editing ends).
    func dismiss() {
        update([])
    }

    /// Spring the panel in from a slightly-raised, transparent state — the "refined" feel: a short
    /// settle with a touch of overshoot, not a hard cut.
    private func animateIn() {
        isHidden = false
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -8)
        UIView.animate(withDuration: 0.35, delay: 0,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    /// Fade out while keeping the current rows on screen, then hide and clear — so dismissal reads as
    /// a smooth dissolve rather than the content vanishing first.
    private func animateOut() {
        guard !isHidden else {
            suggestions = []
            tableView.reloadData()
            return
        }
        UIView.animate(withDuration: 0.2, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.alpha = 0
        } completion: { _ in
            self.isHidden = true
            self.alpha = 1
            self.transform = .identity
            self.suggestions = []
            self.tableView.reloadData()
        }
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
