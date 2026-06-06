//
//  OmniboxView.swift
//  BrownBear
//
//  The rounded address bar. It shows a compact host with a security indicator when idle, and
//  reveals the full editable URL (selected for easy replacement) when tapped — the same
//  affordance Chrome's omnibox uses. Submitting hands raw text to the delegate, which resolves
//  it through OmniboxInputClassifier.
//

import UIKit

@MainActor
protocol OmniboxViewDelegate: AnyObject {
    func omnibox(_ omnibox: OmniboxView, didSubmit text: String)
    func omniboxDidTapReloadStop(_ omnibox: OmniboxView)
    func omniboxDidBeginEditing(_ omnibox: OmniboxView)
}

@MainActor
final class OmniboxView: UIView {

    weak var delegate: OmniboxViewDelegate?

    private let container = UIView()
    private let leadingIcon = UIImageView()
    private let textField = UITextField()
    private let actionButton = UIButton(type: .system)

    /// The full URL string used when the field enters editing mode.
    private var fullURLString: String?
    private var isLoading = false

    var isEditingURL: Bool { textField.isFirstResponder }

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API

    /// Update the bar from the active tab's state. Ignored while the user is editing so we
    /// don't clobber their in-progress text.
    func update(with state: NavigationState) {
        fullURLString = state.url?.absoluteString
        isLoading = state.isLoading
        updateActionButton()

        guard !isEditingURL else { return }
        updateLeadingIcon(for: state)
        if let host = state.displayHost {
            textField.text = host
            textField.textColor = BrownBearTheme.Palette.textPrimary
        } else if let raw = state.url?.absoluteString, !raw.isEmpty {
            textField.text = raw
        } else {
            textField.text = nil
        }
    }

    /// Programmatically begin editing (e.g. when the user taps a new-tab placeholder).
    func beginEditing() {
        textField.becomeFirstResponder()
    }

    func endEditing() {
        textField.resignFirstResponder()
    }

    // MARK: - Build

    private func buildHierarchy() {
        container.backgroundColor = BrownBearTheme.Palette.omniboxFill
        container.layer.cornerRadius = BrownBearTheme.Metrics.omniboxCornerRadius
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        leadingIcon.contentMode = .scaleAspectFit
        leadingIcon.tintColor = BrownBearTheme.Palette.textSecondary
        leadingIcon.translatesAutoresizingMaskIntoConstraints = false
        leadingIcon.setContentHuggingPriority(.required, for: .horizontal)

        textField.font = BrownBearTheme.Typography.omnibox()
        textField.textColor = BrownBearTheme.Palette.textPrimary
        textField.tintColor = BrownBearTheme.Palette.accent
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.keyboardType = .webSearch
        textField.returnKeyType = .go
        textField.clearButtonMode = .never
        textField.placeholder = "Search or enter address"
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        actionButton.tintColor = BrownBearTheme.Palette.textSecondary
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addTarget(self, action: #selector(didTapAction), for: .touchUpInside)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        container.addSubview(leadingIcon)
        container.addSubview(textField)
        container.addSubview(actionButton)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            leadingIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            leadingIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            leadingIcon.widthAnchor.constraint(equalToConstant: 18),
            leadingIcon.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: leadingIcon.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),

            actionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        updateLeadingIcon(for: NavigationState())
        updateActionButton()
    }

    // MARK: - Icon state

    private func updateLeadingIcon(for state: NavigationState) {
        let symbol: String
        let tint: UIColor
        if state.url == nil {
            symbol = "magnifyingglass"
            tint = BrownBearTheme.Palette.textSecondary
        } else if state.hasOnlySecureContent {
            symbol = "lock.fill"
            tint = BrownBearTheme.Palette.secure
        } else {
            symbol = "exclamationmark.triangle.fill"
            tint = BrownBearTheme.Palette.insecure
        }
        leadingIcon.image = UIImage(systemName: symbol)
        leadingIcon.tintColor = tint
    }

    private func updateActionButton() {
        let symbol = isLoading ? "xmark" : "arrow.clockwise"
        actionButton.setImage(UIImage(systemName: symbol), for: .normal)
        actionButton.isHidden = (fullURLString == nil && !isLoading)
    }

    @objc private func didTapAction() {
        delegate?.omniboxDidTapReloadStop(self)
    }
}

// MARK: - UITextFieldDelegate

extension OmniboxView: UITextFieldDelegate {

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Reveal the full URL and select it all so the user can type over it immediately.
        leadingIcon.image = UIImage(systemName: "magnifyingglass")
        leadingIcon.tintColor = BrownBearTheme.Palette.accent
        if let fullURLString { textField.text = fullURLString }
        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
        delegate?.omniboxDidBeginEditing(self)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        textField.resignFirstResponder()
        delegate?.omnibox(self, didSubmit: text)
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        // Collapse back to the compact host representation.
        if let fullURLString, let host = URL(string: fullURLString)?.host {
            textField.text = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }
}
