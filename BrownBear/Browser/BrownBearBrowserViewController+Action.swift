//
//  BrownBearBrowserViewController+Action.swift
//  BrownBear
//
//  The browser's implementation of the chrome.action host surface — the bits that need TabManager
//  and UIKit (the "which tab am I" lookup and the visible click: open the popup, or fire onClicked
//  when there's no popup). The action STATE itself lives in WebExtensionActionState (shared across
//  content/popup/background); this file only bridges that state to the running browser. These methods
//  satisfy the action requirements added to WebExtensionBridgeHost (whose conformance is declared in
//  +WebExtensions). Split into its own +file so it never collides with +WebExtensions.
//

import UIKit

extension BrownBearBrowserViewController {

    /// The chrome tab id of the active tab, or nil if there is none (e.g. an empty window). chrome.
    /// action defaults a tab-less call to the active tab, so the bridge resolves it here.
    func webExtActionActiveTabId() -> Int? {
        guard let active = tabManager.activeTab else { return nil }
        return webExtTabRegistry.id(for: active.id)
    }

    /// A UIColor for a chrome.action badge color (an [r,g,b,a] byte array from WebExtensionActionState),
    /// falling back to the accent color if the bytes are malformed. Used to paint the menu badge pill.
    static func actionBadgeColor(_ bytes: [Int]) -> UIColor {
        guard bytes.count == 4 else { return BrownBearTheme.Palette.accent }
        return UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                       blue: CGFloat(bytes[2]) / 255, alpha: CGFloat(bytes[3]) / 255)
    }

    /// The visible trigger for an extension's action: resolve its popup for the active tab and, if it
    /// has one, present it; otherwise dispatch chrome.action.onClicked to the background worker with
    /// the active Tab record. Called by the overflow-menu action entry (see notes).
    func webExtTriggerAction(extensionID: String) {
        let tabId = webExtActionActiveTabId()
        guard BrownBearServices.shared.webExtensionActionState
                .isEnabled(extensionID: extensionID, tabId: tabId) else { return }

        let popup = BrownBearServices.shared.webExtensionActionState
            .popupPath(extensionID: extensionID, tabId: tabId)

        if let popup, !popup.isEmpty {
            presentActionPopup(extensionID: extensionID)
        } else {
            // No popup → chrome.action.onClicked(tab). Deliver to the extension's background worker.
            let tab = tabManager.activeTab.map(webExtActionTabRecord)
            Task { await BrownBearServices.shared.webExtensionRuntime
                .fireActionClicked(extensionID: extensionID, tab: tab) }
        }
    }

    // MARK: - Helpers

    /// Present the extension's popup as a glassy popover anchored to the toolbar action button, so it
    /// floats over the page (Chrome/Safari-style) instead of covering it as a sheet.
    private func presentActionPopup(extensionID: String) {
        Task { @MainActor in
            guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extensionID) else { return }
            let controller = WebExtensionPageViewController(ext: ext, kind: .popup)
            let anchor = toolbar.actionAnchorView
            present(controller.makePopover(sourceView: anchor, sourceRect: anchor.bounds), animated: true)
        }
    }

    /// The chrome.tabs Tab record passed to onClicked. Mirrors +WebExtensions' tabRecord shape (kept
    /// local so the two +files don't share a private helper across the extension boundary).
    private func webExtActionTabRecord(_ tab: Tab) -> [String: Any] {
        let index = tabManager.tabs.firstIndex { $0.id == tab.id } ?? 0
        let isActive = tab.id == tabManager.activeTabID
        return [
            "id": webExtTabRegistry.id(for: tab.id),
            "index": index,
            "windowId": 1,
            "active": isActive,
            "highlighted": isActive,
            "selected": isActive,
            "pinned": false,
            "audible": false,
            "discarded": false,
            "incognito": tab.isPrivate,
            "url": tab.state.url?.absoluteString ?? "",
            "title": tab.state.displayTitle,
            "status": tab.state.isLoading ? "loading" : "complete"
        ]
    }
}
