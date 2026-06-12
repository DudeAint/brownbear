//
//  BrownBearBrowserViewController+ExtensionsToolbar.swift
//  BrownBear
//
//  The pinnable extensions button in the bottom toolbar (Chrome/Safari's toolbar extension icon, which
//  iOS lacks). It is shown only once at least one extension with a chrome.action is installed and the
//  user hasn't hidden it ("auto-pin on install", hide from its long-press menu, bring back from the
//  Extensions tab). Tapping it opens the single extension's popup directly, or — with several — a glassy
//  list popover to pick one. The popup itself anchors to this button (see BrowserToolbar.actionAnchorView).
//

import UIKit

extension BrownBearBrowserViewController {

    /// Re-evaluate the toolbar icon whenever the extension set or the pin preference changes.
    func registerExtensionsToolbarObservers() {
        extensionsChangeObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshExtensionsToolbarIcon()
        }
        extensionsToolbarPrefObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionsToolbarChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshExtensionsToolbarIcon()
        }
    }

    /// Fetch the enabled extensions that have a clickable action, resolve each one's icon, cache them for
    /// the tap handler, and show/hide the toolbar button accordingly.
    func refreshExtensionsToolbarIcon() {
        let actionTabId = webExtActionActiveTabId()
        Task { @MainActor in
            let store = BrownBearServices.shared.webExtensionStore
            var items: [ExtensionListItem] = []
            let actionState = BrownBearServices.shared.webExtensionActionState
            for ext in await store.enabledExtensions() {
                // Only surface extensions with a browser action — those are the ones a toolbar tap drives.
                guard let manifest = ext.manifest, let action = manifest.action else { continue }
                // Seed the action state now so the FIRST tap works. Without this the state isn't
                // registered until the "•••" menu builds it, and webExtTriggerAction's isEnabled/popup
                // lookup no-ops — the reported "first tap does nothing until you open it from the menu".
                actionState.registerManifestAction(extensionID: ext.id, action: action,
                                                   fallbackIcons: manifest.icons)
                var icon: UIImage?
                if let path = WebExtensionIconResolver.bestIconPath(manifest),
                   let data = await store.file(extensionID: ext.id, path: path) {
                    icon = UIImage(data: data)
                }
                let resolved = actionState.resolved(extensionID: ext.id, tabId: actionTabId)
                let badge = resolved.badgeText.isEmpty ? nil : resolved.badgeText
                items.append(ExtensionListItem(
                    id: ext.id, name: ext.displayName, icon: icon,
                    badge: badge,
                    badgeBackground: badge == nil ? nil
                        : Self.actionBadgeColor(actionState.badgeColorBytes(extensionID: ext.id, tabId: actionTabId)),
                    badgeForeground: badge == nil ? nil
                        : Self.actionBadgeColor(actionState.badgeTextColorBytes(extensionID: ext.id, tabId: actionTabId)),
                    hasPopup: (action.defaultPopup?.isEmpty == false),
                    hasOptions: (manifest.optionsPage?.isEmpty == false),
                    hasSidebar: (manifest.sidePanelPath?.isEmpty == false)))
            }
            self.pinnedExtensionItems = items
            self.toolbar.setExtensionsIconVisible(!AppSettings.extensionsToolbarHidden && !items.isEmpty)
        }
    }

    // MARK: - BrowserToolbarDelegate (extensions button)

    /// Tap: one extension → open its popup (or fire onClicked); several → a glassy list to pick one. Each
    /// row holds for a per-extension menu (open popup/options/side panel · Manage · Uninstall) and the list
    /// ends with an Unpin action.
    func toolbarDidTapExtensions(_ toolbar: BrowserToolbar) {
        let items = pinnedExtensionItems
        if items.count == 1 {
            webExtTriggerAction(extensionID: items[0].id)
        } else if items.count > 1 {
            let anchor = toolbar.actionAnchorView
            let popover = ExtensionsListPopoverViewController(
                items: items,
                onSelect: { [weak self] id in self?.webExtTriggerAction(extensionID: id) },
                onAction: { [weak self] action, item in self?.handleExtensionRowAction(action, item) },
                onUnpin: { [weak self] in self?.unpinExtensionsToolbarIcon() })
            present(popover.makePopover(sourceView: anchor, sourceRect: anchor.bounds), animated: true)
        }
        // count == 0 can't happen (the button is hidden then), so there's nothing to do.
    }

    /// Run a per-extension hold-menu action from the toolbar popover (or the single-icon long-press).
    func handleExtensionRowAction(_ action: ExtensionsListPopoverViewController.RowAction, _ item: ExtensionListItem) {
        switch action {
        case .popup: presentActionPopup(extensionID: item.id)
        case .options: _ = webExtOpenOptionsPage(extensionID: item.id)
        case .sidebar: webExtPresentSidePanel(extensionID: item.id)
        case .manage: presentDashboard(initialTab: .extensions)
        case .uninstall: confirmUninstallExtension(id: item.id, name: item.name)
        }
    }

    /// Hide the toolbar extensions icon (re-show it from the Extensions tab's "Show in toolbar" toggle).
    func unpinExtensionsToolbarIcon() {
        AppSettings.extensionsToolbarHidden = true
        NotificationCenter.default.post(name: .brownBearExtensionsToolbarChanged, object: nil)
    }

    /// Ask before uninstalling — uninstalling deletes the extension's settings and stored data, so this is
    /// a destructive, irreversible action.
    private func confirmUninstallExtension(id: String, name: String) {
        let alert = UIAlertController(
            title: "Uninstall \(name)?",
            message: "This removes the extension and deletes all of its settings and stored data. This can't be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
            self?.uninstallExtension(id: id)
        })
        present(alert, animated: true)
    }

    /// Remove the extension and purge its stored data (mirrors the Extensions tab's remove path), then
    /// notify so the toolbar icon + any open dashboard re-evaluate.
    private func uninstallExtension(id: String) {
        Task { @MainActor in
            let services = BrownBearServices.shared
            await services.webExtensionStore.remove(id: id)
            await services.webExtensionStorage.clearAll(extensionID: id)
            await services.webExtensionDNRStore.clearAll(extensionID: id)
            await services.webExtensionUserScriptStore.clearAll(extensionID: id)
            NotificationCenter.default.post(name: .brownBearExtensionsDidChange, object: nil)
        }
    }

    /// Long-press: manage extensions, or hide the button from the toolbar (re-show it from the
    /// Extensions tab's "Show in toolbar" toggle).
    func toolbarDidLongPressExtensions(_ toolbar: BrowserToolbar) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Manage Extensions", style: .default) { [weak self] _ in
            self?.presentDashboard(initialTab: .extensions)
        })
        sheet.addAction(UIAlertAction(title: "Hide from Toolbar", style: .default) { _ in
            AppSettings.extensionsToolbarHidden = true
            NotificationCenter.default.post(name: .brownBearExtensionsToolbarChanged, object: nil)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad anchors an action sheet to a source rect; harmless on iPhone (presents from the bottom).
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = toolbar.actionAnchorView
            popover.sourceRect = toolbar.actionAnchorView.bounds
        }
        present(sheet, animated: true)
    }
}
