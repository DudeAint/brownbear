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

    /// Replace the displayed suggestions. The panel hides itself when the list is empty.
    func update(_ suggestions: [OmniboxSuggestion]) {
        self.suggestions = suggestions
        isHidden = suggestions.isEmpty
        tableView.reloadData()
        if !suggestions.isEmpty {
            tableView.setContentOffset(.zero, animated: false)
        }
    }

    /// Clear and hide the panel (called when editing ends).
    func dismiss() {
        update([])
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
