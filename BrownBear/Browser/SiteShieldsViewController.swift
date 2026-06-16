//
//  SiteShieldsViewController.swift
//  BrownBear
//
//  The Site Info + Shields panel reached from the omnibox lock/shield glyph (the Brave Shields /
//  Safari "AA" → Website Settings move). A compact popover anchored to the lock: a header showing the
//  page's host and its https/lock state, then a card of per-site toggles that persist per host via
//  SiteSettingsStore and take real effect on reload —
//    • Content blocking (extension declarativeNetRequest rule lists + BrownBear's built-in tracker
//      list) on/off for this host,
//    • JavaScript on/off for this host,
//    • Request the desktop site for this host.
//
//  Programmatic UIKit, themed with BrownBearTheme. Every toggle is real: the delegate persists the
//  choice and reloads the active tab applying the per-site preferences. Split into its own file (well
//  under the SwiftLint length limits); the browser controller owns the persistence + reload wiring via
//  SiteShieldsDelegate.
//

import UIKit

/// A resolved snapshot of the active page the Shields panel renders against. Effective booleans fold
/// the stored per-host override over the app default so the switches show the state actually in force.
struct SiteShieldsState {
    /// Display host (lowercased, "www." stripped) — the per-site scope key the user is editing.
    let host: String
    /// The exact host shown verbatim in the omnibox/lock (may keep "www."), for the identity line.
    let displayHost: String
    /// Whether the page loaded over a valid TLS chain (drives the lock vs. "Not Secure" copy + glyph).
    let isSecure: Bool
    /// The page's scheme ("https"/"http"/…) for the identity subtitle.
    let scheme: String

    /// Effective content-blocking state for this host (override ?? default-on).
    let contentBlockingOn: Bool
    /// Whether content blocking is pinned for this host (vs. following the default) — shows a reset.
    let contentBlockingPinned: Bool
    /// Effective JavaScript-enabled state for this host (override ?? true).
    let javaScriptOn: Bool
    let javaScriptPinned: Bool
    /// Effective desktop-site state for this host (override ?? false).
    let desktopSiteOn: Bool
    let desktopSitePinned: Bool

    /// Count of trackers/ads blocked on the current page so far (best-effort; 0 hides the stat).
    var blockedCount: Int = 0
}

/// Which per-site toggle changed, emitted to the browser controller for persistence + reload.
enum SiteShieldsToggle {
    case contentBlocking
    case javaScript
    case desktopSite
}

@MainActor
protocol SiteShieldsDelegate: AnyObject {
    /// A toggle changed to `isOn`. The controller persists it per host and reloads the active tab so
    /// the new preference takes effect.
    func siteShields(_ controller: SiteShieldsViewController, didSet toggle: SiteShieldsToggle, isOn: Bool)
    /// "Reset to defaults" for this host: clear every per-site override and reload.
    func siteShieldsDidRequestReset(_ controller: SiteShieldsViewController)
}

@MainActor
final class SiteShieldsViewController: UIViewController {

    private let state: SiteShieldsState
    private weak var delegate: SiteShieldsDelegate?

    init(state: SiteShieldsState, delegate: SiteShieldsDelegate) {
        self.state = state
        self.delegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Frosted glass backdrop (was a flat warm fill) so the page stays faintly visible behind.
        GlassBackground.install(in: view)
        buildLayout()
    }

    /// Configure the controller for an arrow-anchored popover from the omnibox lock glyph (iPhone +
    /// iPad alike — the delegate is set so UIKit doesn't fall back to a full-screen sheet on compact
    /// widths). The caller sets `sourceView`/`sourceRect` on the returned popover controller.
    func makePopover(sourceView: UIView, sourceRect: CGRect) -> UIViewController {
        modalPresentationStyle = .popover
        preferredContentSize = CGSize(width: 320, height: preferredHeight())
        if let popover = popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            // The arrow points AT the anchor: a top address bar drops the popover DOWN (arrow up); a
            // BOTTOM address bar raises it UP (arrow down) — otherwise it renders off the bottom edge
            // (the reported bug). Allow both as a fallback so UIKit can still fit it if space is tight.
            popover.permittedArrowDirections = AppSettings.addressBarPosition == .bottom ? [.down, .up] : [.up, .down]
            popover.delegate = self
            // Clear so UIKit doesn't paint an opaque frame over the glass backdrop.
            popover.backgroundColor = .clear
        }
        return self
    }

    /// Intrinsic content height so the popover hugs its rows rather than ballooning. Header + N rows +
    /// the footer reset row, plus the inter-section spacing and outer padding.
    private func preferredHeight() -> CGFloat {
        let header: CGFloat = 76
        let rows: CGFloat = 3 * 56
        let footer: CGFloat = 52
        let chrome: CGFloat = 20 + 16 + 16 + 16 + 20   // top pad + 3 gaps + bottom pad
        return header + rows + footer + chrome
    }

    // MARK: - Layout

    private func buildLayout() {
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let guide = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            root.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -16)
        ])

        root.addArrangedSubview(makeHeader())
        root.addArrangedSubview(makeToggleCard())
        root.addArrangedSubview(makeResetRow())
    }

    /// Site identity: the lock/warning glyph, the host, and a plain-language connection line.
    private func makeHeader() -> UIView {
        let glyph = UIImageView(image: UIImage(systemName: state.isSecure ? "lock.fill" : "exclamationmark.triangle.fill"))
        glyph.tintColor = state.isSecure ? BrownBearTheme.Palette.secure : BrownBearTheme.Palette.insecure
        glyph.contentMode = .scaleAspectFit
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let host = UILabel()
        host.text = state.displayHost
        host.font = .systemFont(ofSize: 17, weight: .bold)
        host.textColor = BrownBearTheme.Palette.textPrimary
        host.numberOfLines = 1
        host.lineBreakMode = .byTruncatingMiddle

        let connection = UILabel()
        connection.text = connectionSummary()
        connection.font = .systemFont(ofSize: 13)
        connection.textColor = state.isSecure ? BrownBearTheme.Palette.textSecondary : BrownBearTheme.Palette.insecure
        connection.numberOfLines = 2

        let text = UIStackView(arrangedSubviews: [host, connection])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [glyph, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func connectionSummary() -> String {
        if state.isSecure {
            if state.blockedCount > 0 {
                return "Connection is secure · \(state.blockedCount) tracker\(state.blockedCount == 1 ? "" : "s") blocked"
            }
            return "Connection is secure (HTTPS)"
        }
        if state.scheme == "http" {
            return "Not secure — this site uses an unencrypted connection"
        }
        return "Connection is not private"
    }

    /// The three Shields toggles in one rounded card with hairline separators.
    private func makeToggleCard() -> UIView {
        let blocking = makeToggleRow(
            icon: "shield.lefthalf.filled",
            title: "Content Blocking",
            subtitle: "Block ads & trackers on this site",
            isOn: state.contentBlockingOn,
            toggle: .contentBlocking)
        let scripts = makeToggleRow(
            icon: "curlybraces",
            title: "JavaScript",
            subtitle: "Allow scripts to run on this site",
            isOn: state.javaScriptOn,
            toggle: .javaScript)
        let desktop = makeToggleRow(
            icon: "desktopcomputer",
            title: "Request Desktop Site",
            subtitle: "Load the full desktop layout",
            isOn: state.desktopSiteOn,
            toggle: .desktopSite)

        let container = UIView()
        // A faint frosted layer on the glass (not the old opaque card) so the backdrop reads through.
        container.backgroundColor = UIColor(dynamicLight: UIColor.white.withAlphaComponent(0.45),
                                            dark: UIColor.white.withAlphaComponent(0.06))
        container.layer.cornerRadius = BrownBearTheme.Metrics.cellCornerRadius
        container.layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: interleaveSeparators([blocking, scripts, desktop]))
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }

    private func makeToggleRow(icon: String, title: String, subtitle: String,
                               isOn: Bool, toggle: SiteShieldsToggle) -> UIView {
        let glyph = UIImageView(image: UIImage(systemName: icon))
        glyph.tintColor = isOn ? BrownBearTheme.Palette.accent : BrownBearTheme.Palette.textSecondary
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([glyph.widthAnchor.constraint(equalToConstant: 22),
                                     glyph.heightAnchor.constraint(equalToConstant: 22)])

        let name = UILabel()
        name.text = title
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = BrownBearTheme.Palette.textPrimary

        let detail = UILabel()
        detail.text = subtitle
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = BrownBearTheme.Palette.textSecondary
        detail.numberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail

        let labels = UIStackView(arrangedSubviews: [name, detail])
        labels.axis = .vertical
        labels.spacing = 1

        let toggleSwitch = UISwitch()
        toggleSwitch.isOn = isOn
        toggleSwitch.onTintColor = BrownBearTheme.Palette.toggleOn
        toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)
        toggleSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggleSwitch.addAction(UIAction { [weak self, weak toggleSwitch, weak glyph] _ in
            guard let self, let toggleSwitch else { return }
            glyph?.tintColor = toggleSwitch.isOn ? BrownBearTheme.Palette.accent : BrownBearTheme.Palette.textSecondary
            self.delegate?.siteShields(self, didSet: toggle, isOn: toggleSwitch.isOn)
        }, for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [glyph, labels, toggleSwitch])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        return row
    }

    /// A trailing "Reset to defaults" row, shown only when this host actually pins an override.
    private func makeResetRow() -> UIView {
        let pinned = state.contentBlockingPinned || state.javaScriptPinned || state.desktopSitePinned
        var config = UIButton.Configuration.plain()
        config.title = pinned ? "Reset This Site to Defaults" : "No custom settings for this site"
        config.image = pinned ? UIImage(systemName: "arrow.counterclockwise") : nil
        config.imagePadding = 8
        config.baseForegroundColor = pinned ? BrownBearTheme.Palette.accent : BrownBearTheme.Palette.textTertiary
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4)
        var titleAttr = AttributeContainer()
        titleAttr.font = .systemFont(ofSize: 14, weight: .medium)
        config.attributedTitle = AttributedString(config.title ?? "", attributes: titleAttr)
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .center
        button.isEnabled = pinned
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.siteShieldsDidRequestReset(self)
            self.dismiss(animated: true)
        }, for: .touchUpInside)
        return button
    }

    /// Insert hairline separators (inset past the leading glyph) between rows.
    private func interleaveSeparators(_ rows: [UIView]) -> [UIView] {
        var out: [UIView] = []
        for (index, row) in rows.enumerated() {
            out.append(row)
            guard index < rows.count - 1 else { continue }
            let line = UIView()
            line.backgroundColor = BrownBearTheme.Palette.separator
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.hairline).isActive = true
            let inset = UIView()
            inset.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 48),
                line.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
                line.topAnchor.constraint(equalTo: inset.topAnchor),
                line.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
                inset.heightAnchor.constraint(equalToConstant: BrownBearTheme.Metrics.hairline)
            ])
            out.append(inset)
        }
        return out
    }
}

// MARK: - UIPopoverPresentationControllerDelegate

extension SiteShieldsViewController: UIPopoverPresentationControllerDelegate {
    /// Force a true popover (with arrow) on compact widths too, instead of UIKit's default adaptive
    /// full-screen sheet — the Shields panel is small and reads best anchored to the lock glyph.
    nonisolated func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
