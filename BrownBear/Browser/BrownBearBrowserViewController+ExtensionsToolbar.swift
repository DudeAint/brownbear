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
        Task { @MainActor in
            let store = BrownBearServices.shared.webExtensionStore
            var items: [ExtensionListItem] = []
            let actionState = BrownBearServices.shared.webExtensionActionState
            for ext in await store.enabledExtensions() {
                // Only surface extensions with a browser action — those are the ones a toolbar tap drives.
                guard let action = ext.manifest?.action else { continue }
                // Seed the action state now so the FIRST tap works. Without this the state isn't
                // registered until the "•••" menu builds it, and webExtTriggerAction's isEnabled/popup
                // lookup no-ops — the reported "first tap does nothing until you open it from the menu".
                actionState.registerManifestAction(extensionID: ext.id, action: action,
                                                   fallbackIcons: ext.manifest?.icons ?? [:])
                var icon: UIImage?
                if let path = WebExtensionIconResolver.bestIconPath(ext.manifest),
                   let data = await store.file(extensionID: ext.id, path: path) {
                    icon = UIImage(data: data)
                }
                items.append(ExtensionListItem(id: ext.id, name: ext.displayName, icon: icon))
            }
            self.pinnedExtensionItems = items
            self.toolbar.setExtensionsIconVisible(!AppSettings.extensionsToolbarHidden && !items.isEmpty)
        }
    }

    // MARK: - BrowserToolbarDelegate (extensions button)

    /// Tap: one extension → open its popup (or fire onClicked); several → a glassy list to pick one.
    func toolbarDidTapExtensions(_ toolbar: BrowserToolbar) {
        let items = pinnedExtensionItems
        if items.count == 1 {
            webExtTriggerAction(extensionID: items[0].id)
        } else if items.count > 1 {
            let anchor = toolbar.actionAnchorView
            let popover = ExtensionsListPopoverViewController(items: items) { [weak self] id in
                self?.webExtTriggerAction(extensionID: id)
            }
            present(popover.makePopover(sourceView: anchor, sourceRect: anchor.bounds), animated: true)
        }
        // count == 0 can't happen (the button is hidden then), so there's nothing to do.
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
