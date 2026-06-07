//
//  OmniboxView.swift
//  BrownBear
//
//  The rounded address bar. Idle, it shows a two-tone URL — the registrable host in primary text,
//  the scheme and path dimmed — behind a security glyph, with a soft trailing fade for overflow.
//  Tapped, it swaps the display label for a live, select-all text field (Brave/Firefox swap), the
//  glyph crossfades to a search icon, and a clear button appears. Submitting hands raw text to the
//  delegate, which resolves it through OmniboxInputClassifier. The pill floats on a soft shadow in
//  light and a hairline border in dark, where shadows wash out.
//

import UIKit

/// The @MainActor callback channel from the omnibox to its owner (the browser controller):
/// URL submission, reload/stop taps, and edit-begin notifications.
@MainActor
protocol OmniboxViewDelegate: AnyObject {
    func omnibox(_ omnibox: OmniboxView, didSubmit text: String)
    func omniboxDidTapReloadStop(_ omnibox: OmniboxView)
    func omniboxDidBeginEditing(_ omnibox: OmniboxView)
    /// The edit text changed (each keystroke), so suggestions can be refreshed live.
    func omnibox(_ omnibox: OmniboxView, didChangeText text: String)
    /// Editing ended (the field resigned first responder), so suggestions can be dismissed.
    func omniboxDidEndEditing(_ omnibox: OmniboxView)
}

// Default no-ops so the two suggestion hooks are effectively optional for conformers that don't
// surface a suggestions UI.
extension OmniboxViewDelegate {
    func omnibox(_ omnibox: OmniboxView, didChangeText text: String) {}
    func omniboxDidEndEditing(_ omnibox: OmniboxView) {}
}

/// The rounded address bar — @MainActor-isolated. Owns the display↔edit transition, the two-tone
/// URL rendering, and the floating-pill chrome. Public surface: `delegate`, `isEditingURL`,
/// `update(with:)`, `beginEditing()`, `endEditing()`.
@MainActor
final class OmniboxView: UIView {

    weak var delegate: OmniboxViewDelegate?

    private let container = UIView()
    private let contentStack = UIStackView()
    private let securityIconContainer = UIView()
    private let searchGlyph = UIImageView()
    private let lockGlyph = UIImageView()
    private let fieldZone = UIView()
    private let urlLabel = FadingLabel()
    private let textField = UITextField()
    private let actionButton = UIButton(type: .system)

    /// The full URL string used when the field enters editing mode.
    private var fullURLString: String?
    /// The latest pushed state, used to rebuild the display URL/icon after editing ends.
    private var currentState = NavigationState()
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
        currentState = state
        fullURLString = state.url?.absoluteString
        isLoading = state.isLoading
        updateActionButton()

        guard !isEditingURL else { return }
        applyIconState(editing: false, animated: false)
        applyDisplayURL(state)
    }

    /// Programmatically begin editing (e.g. when the user taps a new-tab placeholder).
    func beginEditing() {
        enterEditMode()
    }

    func endEditing() {
        textField.resignFirstResponder()
    }

    // MARK: - Build

    private func buildHierarchy() {
        container.backgroundColor = BrownBearTheme.Palette.surfaceField
        container.layer.cornerRadius = BrownBearTheme.Metrics.omniboxCornerRadius
        container.layer.cornerCurve = .continuous
        // The pill floats: keep it unclipped so its shadow can render (content is inset, so it
        // never spills past the rounded corners).
        container.clipsToBounds = false
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        buildSecurityIcon()
        buildField()
        buildActionButton()

        contentStack.axis = .horizontal
        contentStack.alignment = .fill
        contentStack.spacing = BrownBearTheme.Space.s
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(securityIconContainer)
        contentStack.addArrangedSubview(fieldZone)
        contentStack.addArrangedSubview(actionButton)
        container.addSubview(contentStack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                  constant: BrownBearTheme.Space.m),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                   constant: -BrownBearTheme.Space.s),
            contentStack.topAnchor.constraint(equalTo: container.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        applyIconState(editing: false, animated: false)
        applyDisplayURL(NavigationState())
        updateActionButton()
        refreshPillElevation()
    }

    private func buildSecurityIcon() {
        securityIconContainer.translatesAutoresizingMaskIntoConstraints = false
        securityIconContainer.setContentHuggingPriority(.required, for: .horizontal)
        securityIconContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        for glyph in [searchGlyph, lockGlyph] {
            glyph.contentMode = .scaleAspectFit
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.preferredSymbolConfiguration = BrownBearTheme.Typography.symbol(pointSize: 16)
            securityIconContainer.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: securityIconContainer.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: securityIconContainer.centerYAnchor),
                glyph.widthAnchor.constraint(equalToConstant: 18),
                glyph.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
        searchGlyph.image = UIImage(systemName: "magnifyingglass")

        NSLayoutConstraint.activate([
            securityIconContainer.widthAnchor.constraint(equalToConstant: 24)
        ])

        // Tapping the icon area focuses the bar, like the URL itself.
        securityIconContainer.isUserInteractionEnabled = true
        securityIconContainer.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleFieldTap)))
    }

    private func buildField() {
        fieldZone.translatesAutoresizingMaskIntoConstraints = false
        fieldZone.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fieldZone.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        urlLabel.font = BrownBearTheme.Typography.omniboxScaled()
        urlLabel.numberOfLines = 1
        urlLabel.lineBreakMode = .byClipping        // overflow handled by the trailing fade mask
        urlLabel.textAlignment = .natural
        urlLabel.isUserInteractionEnabled = true
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleFieldTap)))

        textField.font = BrownBearTheme.Typography.omniboxScaled()
        textField.textColor = BrownBearTheme.Palette.textPrimary
        textField.tintColor = BrownBearTheme.Palette.accent
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.keyboardType = .webSearch
        textField.returnKeyType = .go
        textField.clearButtonMode = .whileEditing
        textField.placeholder = "Search or enter address"
        textField.delegate = self
        textField.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)
        textField.isHidden = true
        textField.translatesAutoresizingMaskIntoConstraints = false

        fieldZone.addSubview(urlLabel)
        fieldZone.addSubview(textField)
        NSLayoutConstraint.activate([
            urlLabel.leadingAnchor.constraint(equalTo: fieldZone.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: fieldZone.trailingAnchor),
            urlLabel.centerYAnchor.constraint(equalTo: fieldZone.centerYAnchor),
            urlLabel.topAnchor.constraint(greaterThanOrEqualTo: fieldZone.topAnchor),
            urlLabel.bottomAnchor.constraint(lessThanOrEqualTo: fieldZone.bottomAnchor),

            textField.leadingAnchor.constraint(equalTo: fieldZone.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: fieldZone.trailingAnchor),
            textField.topAnchor.constraint(equalTo: fieldZone.topAnchor),
            textField.bottomAnchor.constraint(equalTo: fieldZone.bottomAnchor)
        ])
    }

    private func buildActionButton() {
        actionButton.tintColor = BrownBearTheme.Palette.textSecondary
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        // The fixed 28pt width pins the slot and the image fits inside it. We must NOT also force
        // required hugging/compression: the button's intrinsic image width rarely equals 28, so a
        // required intrinsic-width constraint would fight the width equality and log Auto Layout
        // conflicts. scaleAspectFit keeps an oversized glyph inside the slot.
        actionButton.imageView?.contentMode = .scaleAspectFit
        actionButton.addTarget(self, action: #selector(didTapAction), for: .touchUpInside)
        NSLayoutConstraint.activate([
            actionButton.widthAnchor.constraint(equalToConstant: 28)
        ])
    }

    // MARK: - Display URL

    private func applyDisplayURL(_ state: NavigationState) {
        textField.isHidden = true
        urlLabel.isHidden = false
        if let url = state.url, !url.absoluteString.isEmpty {
            urlLabel.attributedText = attributedDisplayURL(for: url)
        } else {
            urlLabel.attributedText = NSAttributedString(
                string: "Search or enter address",
                attributes: [.foregroundColor: BrownBearTheme.Palette.textTertiary,
                             .font: BrownBearTheme.Typography.omniboxScaled()])
        }
    }

    /// Two-tone URL: the host (minus a leading `www.`) is emphasized, everything else dimmed.
    ///
    /// The displayed text is the URL's `absoluteString` VERBATIM — we only restyle a substring,
    /// never reconstruct the URL from components. Reconstructing would percent-decode the path
    /// (while query/fragment stay encoded) and drop any `user:pass@` userinfo — both let a hostile
    /// page spoof the bar (encoded slashes/control chars decoding into view, or a
    /// `login.bank.com@evil.com` credential trick rendered as a clean `evil.com`). IDN hosts are
    /// shown in their punycode (`xn--`) form as the URL carries them — intentional, anti-homograph.
    private func attributedDisplayURL(for url: URL) -> NSAttributedString {
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: BrownBearTheme.Palette.textSecondary,
            .font: BrownBearTheme.Typography.omniboxScaled()]
        let strongAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: BrownBearTheme.Palette.textPrimary,
            .font: BrownBearTheme.Typography.scaled(16, .semibold, .body, maximumPointSize: 24)]

        let full = url.absoluteString
        let attributed = NSMutableAttributedString(string: full, attributes: dimAttrs)
        guard let host = url.host,
              let emphasis = OmniboxView.hostEmphasisRange(in: full, host: host) else {
            // No host (about:, data:, file:, …) or host not locatable — emphasize the whole string.
            attributed.setAttributes(strongAttrs, range: NSRange(full.startIndex..., in: full))
            return attributed
        }
        attributed.setAttributes(strongAttrs, range: NSRange(emphasis, in: full))
        return attributed
    }

    /// The substring range of `full` (a URL's `absoluteString`) to emphasize: the AUTHORITY host
    /// minus a leading `www.`. Pure and `nonisolated` so the anti-spoofing logic is unit-testable
    /// without a view. Returns nil when there is no host to emphasize (caller bolds the whole string).
    ///
    /// Anti-spoofing: the host search begins after the last `@` *inside the authority*, so a crafted
    /// `https://real.com@evil.com/` emphasizes the true host `evil.com`, never the userinfo copy.
    nonisolated static func hostEmphasisRange(in full: String, host: String) -> Range<String.Index>? {
        guard !host.isEmpty else { return nil }
        let afterScheme = full.range(of: "://")?.upperBound ?? full.startIndex
        let authorityEnd = full[afterScheme...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? full.endIndex
        let hostStart = full.range(of: "@", options: .backwards, range: afterScheme..<authorityEnd)?.upperBound ?? afterScheme
        guard let hostRange = full.range(of: host, range: hostStart..<full.endIndex) else { return nil }
        // Strip a leading "www." only when it is a real subdomain (a dot remains), so a host like
        // "www.com" isn't over-trimmed to "com".
        let stripWWW = host.hasPrefix("www.") && host.dropFirst(4).contains(".")
        let emphasisStart = stripWWW
            ? full.index(hostRange.lowerBound, offsetBy: 4, limitedBy: hostRange.upperBound) ?? hostRange.lowerBound
            : hostRange.lowerBound
        return emphasisStart..<hostRange.upperBound
    }

    // MARK: - Icon state

    /// Crossfade the leading glyph: a search icon while editing or when there's no URL, otherwise
    /// the security lock/warning. Tints follow state — accent search while editing, neutral at rest.
    private func applyIconState(editing: Bool, animated: Bool) {
        searchGlyph.tintColor = editing ? BrownBearTheme.Palette.accent : BrownBearTheme.Palette.textSecondary
        if currentState.hasOnlySecureContent {
            lockGlyph.image = UIImage(systemName: "lock.fill")
            lockGlyph.tintColor = BrownBearTheme.Palette.secure
        } else {
            lockGlyph.image = UIImage(systemName: "exclamationmark.triangle.fill")
            lockGlyph.tintColor = BrownBearTheme.Palette.insecure
        }

        let showSearch = editing || (currentState.url == nil)
        let apply = {
            self.searchGlyph.alpha = showSearch ? 1 : 0
            self.lockGlyph.alpha = showSearch ? 0 : 1
        }
        guard animated else { apply(); return }
        UIView.animate(withDuration: BrownBearTheme.Motion.crossfade,
                       delay: 0, options: [.beginFromCurrentState], animations: apply)
    }

    private func updateActionButton() {
        let symbol = isLoading ? "xmark" : "arrow.clockwise"
        // A fixed (non-Dynamic-Type) symbol config so the glyph can't outgrow the fixed 28pt slot at
        // large accessibility text sizes (which would conflict with the width constraint).
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular, scale: .medium)
        actionButton.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        // Reload/stop is irrelevant while editing (the clear button serves the trailing slot) and
        // when there's nothing loaded yet.
        actionButton.isHidden = isEditingURL || (fullURLString == nil && !isLoading)
    }

    // MARK: - Editing transition

    private func enterEditMode() {
        guard !isEditingURL else { return }
        textField.text = fullURLString ?? ""
        urlLabel.isHidden = true
        textField.isHidden = false
        // If focus is refused (e.g. not yet in a window), revert the swap so the bar isn't stranded
        // showing an empty field with no keyboard.
        if !textField.becomeFirstResponder() {
            textField.isHidden = true
            urlLabel.isHidden = false
        }
    }

    @objc private func handleFieldTap() {
        enterEditMode()
    }

    @objc private func didTapAction() {
        delegate?.omniboxDidTapReloadStop(self)
    }

    @objc private func textFieldEditingChanged() {
        delegate?.omnibox(self, didChangeText: textField.text ?? "")
    }

    // MARK: - Elevation (light shadow / dark border)

    override func layoutSubviews() {
        super.layoutSubviews()
        container.layer.shadowPath = UIBezierPath(
            roundedRect: container.bounds,
            cornerRadius: BrownBearTheme.Metrics.omniboxCornerRadius).cgPath
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refreshPillElevation()
    }

    /// In light mode the pill floats on a soft shadow; in dark mode shadows wash out on near-black,
    /// so it instead gets a 1px border and no shadow.
    private func refreshPillElevation() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if isDark {
            container.layer.shadowOpacity = 0
            container.layer.borderWidth = BrownBearTheme.Metrics.hairline
            container.layer.borderColor = BrownBearTheme.Palette.borderStrong.cgColor
        } else {
            container.layer.borderWidth = 0
            BrownBearTheme.Elevation.level2.apply(to: container.layer, traits: traitCollection)
        }
    }

    // MARK: - FadingLabel

    /// A single-line label that fades its trailing edge to transparent, so an overflowing URL
    /// dissolves instead of showing an ellipsis (Firefox). The mask tracks the label's bounds.
    private final class FadingLabel: UILabel {
        private let fadeMask = CAGradientLayer()
        private let fadeWidth: CGFloat = 22

        override init(frame: CGRect) {
            super.init(frame: frame)
            fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
            fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
            // Mask uses the alpha channel only: opaque (visible) → clear (faded).
            fadeMask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
            layer.mask = fadeMask
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let width = bounds.width
            // When the label is narrower than the fade, don't fade at all (start = 1) — otherwise
            // a tiny/zero-width label would dissolve entirely.
            let start = width > fadeWidth ? Double((width - fadeWidth) / width) : 1
            // Fade the trailing edge — right in LTR, left in RTL — by flipping the gradient axis.
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            // The mask geometry/stops must update instantly with layout, never animate.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeMask.frame = bounds
            fadeMask.startPoint = CGPoint(x: rtl ? 1 : 0, y: 0.5)
            fadeMask.endPoint = CGPoint(x: rtl ? 0 : 1, y: 0.5)
            fadeMask.locations = [0, NSNumber(value: start), 1]
            CATransaction.commit()
        }
    }
}

// MARK: - UITextFieldDelegate

extension OmniboxView: UITextFieldDelegate {

    func textFieldDidBeginEditing(_ textField: UITextField) {
        applyIconState(editing: true, animated: true)
        updateActionButton()
        // Select all so the user can type over the URL immediately.
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
        // Collapse back to the two-tone display representation.
        applyIconState(editing: false, animated: true)
        applyDisplayURL(currentState)
        updateActionButton()
        delegate?.omniboxDidEndEditing(self)
    }
}
