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

    /// Show, hide, or restyle the install banner based on whether `url` is a Chrome Web Store *detail*
    /// page and whether that extension is already installed. Called on every active-tab navigation tick
    /// (full loads and the store's in-page SPA nav) and after the banner's own Add/Remove completes.
    func updateExtensionInstallBanner(url: URL?) {
        guard let url, let extensionID = Self.chromeWebStoreExtensionID(for: url) else {
            dismissExtensionInstallBanner()
            return
        }
        let name = Self.chromeWebStoreName(from: url)
        Task { @MainActor in
            let installed = await BrownBearServices.shared.webExtensionStore.installed(forStoreID: extensionID) != nil
            // Bail if the active tab navigated off this store page while we awaited the store.
            let activeID = tabManager.activeTab?.state.url.flatMap(Self.chromeWebStoreExtensionID)
            guard activeID == extensionID else { return }
            // Key on id + state so a state change (installed via the in-page button) restyles the pill,
            // but the same id+state is left in place (no flicker on every loading tick).
            let key = "\(extensionID)|\(installed)"
            if extensionInstallBanner?.accessibilityIdentifier == key { return }
            presentExtensionInstallBanner(extensionID: extensionID, name: name, installed: installed)
        }
    }

    /// Re-evaluate the banner for the active tab (after the banner's own Add/Remove changes state).
    private func refreshExtensionInstallBanner() {
        updateExtensionInstallBanner(url: tabManager.activeTab?.state.url)
    }

    /// True for ANY Chrome Web Store page (detail, search, category…), used to force a desktop Chrome
    /// experience on the whole store. Covers the current `chromewebstore.google.com` host and the
    /// legacy `chrome.google.com/webstore` path.
    static func isChromeWebStoreURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && url.path.hasPrefix("/webstore"))
    }

    /// A desktop Chrome User-Agent. Sending this for store hosts makes the store serve its desktop
    /// "Add to Chrome" experience (enabled button, no "you're not on Chrome" banner).
    static let desktopChromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// A desktop Safari User-Agent — the default desktop UA for the manual "Request Desktop Site" toggle.
    static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// The 32-char extension id if `url` is a Chrome Web Store detail page, else nil.
    static func chromeWebStoreExtensionID(for url: URL) -> String? {
        guard isChromeWebStoreURL(url) else { return nil }
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

    private func presentExtensionInstallBanner(extensionID: String, name: String, installed: Bool) {
        extensionInstallBanner?.removeFromSuperview()   // replace a banner for a different ext/state

        let banner = UIView()
        banner.accessibilityIdentifier = "\(extensionID)|\(installed)"
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

        let iconName = installed ? "checkmark.seal.fill" : "puzzlepiece.extension.fill"
        let icon = UIImageView(image: UIImage(systemName: iconName))
        icon.tintColor = BrownBearTheme.Palette.accent
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = installed ? "“\(name)” is added to BrownBear" : "Add “\(name)” to BrownBear"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = BrownBearTheme.Palette.textPrimary
        label.numberOfLines = 2

        var addConfig = UIButton.Configuration.filled()
        addConfig.title = installed ? "Remove" : "Add"
        addConfig.baseBackgroundColor = installed ? BrownBearTheme.Palette.destructive : BrownBearTheme.Palette.accent
        addConfig.baseForegroundColor = .white
        addConfig.cornerStyle = .capsule
        addConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        let addButton = UIButton(configuration: addConfig)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.addAction(UIAction { [weak self, weak addButton] _ in
            guard let self, let addButton else { return }
            if installed {
                self.performExtensionRemove(extensionID: extensionID, name: name, button: addButton)
            } else {
                self.performExtensionInstall(extensionID: extensionID, name: name, button: addButton)
            }
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

    private func performExtensionInstall(extensionID: String, name: String, button: UIButton) {
        button.isEnabled = false
        button.configuration?.showsActivityIndicator = true
        Task { @MainActor in
            do {
                let data = try await ChromeWebStore.downloadCRX(forInput: extensionID)
                _ = try await BrownBearServices.shared.webExtensionStore.install(archive: data, storeID: extensionID)
                NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
                presentExtensionToast(message: "Added “\(name)” to BrownBear")
                refreshExtensionInstallBanner()   // flip the pill to the "Remove" state
            } catch {
                button.isEnabled = true
                button.configuration?.showsActivityIndicator = false
                presentError(error)
            }
        }
    }

    private func performExtensionRemove(extensionID: String, name: String, button: UIButton) {
        button.isEnabled = false
        button.configuration?.showsActivityIndicator = true
        Task { @MainActor in
            let store = BrownBearServices.shared.webExtensionStore
            if let ext = await store.installed(forStoreID: extensionID) {
                await store.remove(id: ext.id)
                NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
            }
            presentExtensionToast(message: "Removed “\(name)” from BrownBear")
            refreshExtensionInstallBanner()   // flip the pill back to the "Add" state
        }
    }

    private func presentExtensionToast(message: String) {
        let container = UIView()
        container.backgroundColor = BrownBearTheme.Palette.accent
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.alpha = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = message
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
