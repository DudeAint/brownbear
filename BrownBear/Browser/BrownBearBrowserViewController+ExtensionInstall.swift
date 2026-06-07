//
//  BrownBearBrowserViewController+ExtensionInstall.swift
//  BrownBear
//
//  The in-page "Add to BrownBear" affordance for the Chrome Web Store — the Orion/Kiwi move that
//  turns a store detail page into a one-tap install. When the active tab lands on a Chrome Web Store
//  extension page, a banner appears above the toolbar; tapping Add pulls the CRX from Google's public
//  download endpoint (ChromeWebStore) and installs it through the normal WebExtensionStore path.
//  Split into its own file to keep the browser controller under the SwiftLint length limit; the
//  shared members it touches (toolbar, extensionInstallBanner, presentError) are internal for that.
//

import UIKit

extension BrownBearBrowserViewController {

    /// Show or hide the install banner based on whether `url` is a Chrome Web Store *detail* page.
    /// Called on every active-tab navigation tick (full loads and the store's in-page SPA nav).
    func updateExtensionInstallBanner(url: URL?) {
        guard let url, let extensionID = Self.chromeWebStoreExtensionID(for: url) else {
            dismissExtensionInstallBanner()
            return
        }
        // Already showing this exact extension — leave it in place (no rebuild, no flicker).
        if extensionInstallBanner?.accessibilityIdentifier == extensionID { return }
        presentExtensionInstallBanner(extensionID: extensionID, name: Self.chromeWebStoreName(from: url))
    }

    /// The 32-char extension id if `url` is a Chrome Web Store detail page, else nil. Covers both the
    /// current `chromewebstore.google.com` host and the legacy `chrome.google.com/webstore` path.
    static func chromeWebStoreExtensionID(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let isStore = host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && url.path.hasPrefix("/webstore"))
        guard isStore else { return nil }
        return ChromeWebStore.extensionID(from: url.absoluteString)
    }

    /// A human-ish name from the store URL's slug (".../detail/<slug>/<id>"); "this extension" if absent.
    static func chromeWebStoreName(from url: URL) -> String {
        let components = url.pathComponents
        if let idIndex = components.firstIndex(where: { ChromeWebStore.isExtensionID($0) }), idIndex > 0 {
            let slug = components[idIndex - 1]
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            // Require an actual word: skips the path root ("/") and the "detail" segment.
            if slug.lowercased() != "detail", slug.rangeOfCharacter(from: .letters) != nil {
                return slug.capitalized
            }
        }
        return "this extension"
    }

    private func dismissExtensionInstallBanner() {
        guard let banner = extensionInstallBanner else { return }
        extensionInstallBanner = nil
        UIView.animate(withDuration: 0.2, animations: { banner.alpha = 0 }) { _ in
            banner.removeFromSuperview()
        }
    }

    private func presentExtensionInstallBanner(extensionID: String, name: String) {
        extensionInstallBanner?.removeFromSuperview()   // replace a banner for a different extension

        let banner = UIView()
        banner.accessibilityIdentifier = extensionID
        banner.backgroundColor = BrownBearTheme.Palette.chrome
        banner.layer.cornerRadius = 16
        banner.layer.cornerCurve = .continuous
        banner.layer.borderWidth = BrownBearTheme.Metrics.hairline
        banner.layer.borderColor = BrownBearTheme.Palette.borderSubtle.cgColor
        banner.layer.shadowColor = UIColor.black.cgColor
        banner.layer.shadowOpacity = 0.18
        banner.layer.shadowRadius = 10
        banner.layer.shadowOffset = CGSize(width: 0, height: 3)
        banner.alpha = 0
        banner.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "puzzlepiece.extension.fill"))
        icon.tintColor = BrownBearTheme.Palette.accent
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = "Add “\(name)” to BrownBear"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = BrownBearTheme.Palette.textPrimary
        label.numberOfLines = 2

        var addConfig = UIButton.Configuration.filled()
        addConfig.title = "Add"
        addConfig.baseBackgroundColor = BrownBearTheme.Palette.accent
        addConfig.baseForegroundColor = .white
        addConfig.cornerStyle = .capsule
        addConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        let addButton = UIButton(configuration: addConfig)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.addAction(UIAction { [weak self, weak addButton] _ in
            guard let self, let addButton else { return }
            self.performExtensionInstall(extensionID: extensionID, button: addButton)
        }, for: .touchUpInside)

        let close = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.dismissExtensionInstallBanner()
        })
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = BrownBearTheme.Palette.textSecondary
        close.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [icon, label, addButton, close])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)
        view.addSubview(banner)
        extensionInstallBanner = banner

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            banner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            banner.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -10)
        ])

        UIView.animate(withDuration: 0.25) { banner.alpha = 1 }
    }

    private func performExtensionInstall(extensionID: String, button: UIButton) {
        button.isEnabled = false
        button.configuration?.showsActivityIndicator = true
        Task { @MainActor in
            do {
                let data = try await ChromeWebStore.downloadCRX(forInput: extensionID)
                let installed = try await BrownBearServices.shared.webExtensionStore.install(archive: data)
                NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                dismissExtensionInstallBanner()
                presentExtensionInstalledToast(name: installed.displayName)
            } catch {
                button.isEnabled = true
                button.configuration?.showsActivityIndicator = false
                presentError(error)
            }
        }
    }

    private func presentExtensionInstalledToast(name: String) {
        let container = UIView()
        container.backgroundColor = BrownBearTheme.Palette.accent
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.alpha = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Added “\(name)” to BrownBear"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12)
        ])

        UIView.animate(withDuration: 0.25, animations: { container.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 2.4, options: []) {
                container.alpha = 0
            } completion: { _ in container.removeFromSuperview() }
        }
    }
}
