//
//  BrownBearBrowserViewController+Zoom.swift
//  BrownBear
//
//  Page zoom for the browser: a small floating −/+/Done control above the toolbar that adjusts the
//  active tab's `WKWebView.pageZoom` live and remembers the level per host (via SiteSettingsStore).
//  Split out of BrownBearBrowserViewController to keep that file under the SwiftLint length limit.
//  The transient HUD's stored references (`zoomHUD`/`zoomLabel`) live on the main class — Swift
//  extensions can't add stored properties.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController {

    /// Apply the host's remembered zoom to a freshly committed page (default 1.0). Private tabs are
    /// excluded — they don't read or write persisted per-site prefs.
    func applyStoredZoom(for webView: WKWebView) {
        guard let tab = tabManager.tabs.first(where: { $0.webView === webView }),
              !tab.isPrivate, let url = webView.url else { return }
        Task { @MainActor in
            let zoom = await BrownBearServices.shared.siteSettingsStore.settings(for: url).zoom
            webView.pageZoom = CGFloat(zoom ?? 1.0)
        }
    }

    /// A small floating zoom control above the toolbar: − [percent] + and Done. Adjusts the active
    /// tab's pageZoom live (you see the page reflow behind it) and remembers the level per host.
    func presentZoomHUD() {
        guard tabManager.activeTab != nil else { return }
        zoomHUD?.removeFromSuperview()

        let container = UIView()
        container.backgroundColor = BrownBearTheme.Palette.chrome
        container.layer.cornerRadius = 22
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = BrownBearTheme.Metrics.hairline
        container.layer.borderColor = BrownBearTheme.Palette.borderSubtle.cgColor
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.25
        container.layer.shadowRadius = 12
        container.layer.shadowOffset = CGSize(width: 0, height: 4)
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = BrownBearTheme.Palette.textPrimary
        label.textAlignment = .center
        label.text = currentZoomText()
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(resetZoomTapped)))
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        zoomLabel = label

        let minus = zoomButton(symbol: "minus") { [weak self] in self?.adjustZoom(by: -0.1) }
        let plus = zoomButton(symbol: "plus") { [weak self] in self?.adjustZoom(by: 0.1) }
        let done = UIButton(type: .system, primaryAction: UIAction(title: "Done") { [weak self] _ in
            self?.dismissZoomHUD()
        })
        done.tintColor = BrownBearTheme.Palette.accent
        done.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: [minus, label, plus, done])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        view.addSubview(container)
        zoomHUD = container

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12)
        ])
    }

    private func zoomButton(symbol: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.tintColor = BrownBearTheme.Palette.textPrimary
        return button
    }

    private func currentZoomText() -> String {
        let zoom = tabManager.activeTab?.webView.pageZoom ?? 1.0
        return "\(Int((zoom * 100).rounded()))%"
    }

    private func adjustZoom(by delta: CGFloat) {
        guard let tab = tabManager.activeTab else { return }
        tab.webView.pageZoom = min(3.0, max(0.5, tab.webView.pageZoom + delta))
        zoomLabel?.text = currentZoomText()
        persistZoom(tab.webView.pageZoom, for: tab)
    }

    @objc private func resetZoomTapped() {
        guard let tab = tabManager.activeTab else { return }
        tab.webView.pageZoom = 1.0
        zoomLabel?.text = currentZoomText()
        persistZoom(1.0, for: tab)
    }

    /// Remember the per-host zoom (nil prunes back to the 1.0 default). Private tabs aren't persisted.
    private func persistZoom(_ zoom: CGFloat, for tab: Tab) {
        guard !tab.isPrivate, let url = tab.state.url else { return }
        let value: Double? = abs(zoom - 1.0) < 0.001 ? nil : Double(zoom)
        Task { await BrownBearServices.shared.siteSettingsStore.setZoom(value, for: url) }
    }

    private func dismissZoomHUD() {
        zoomHUD?.removeFromSuperview()
        zoomHUD = nil
    }
}
