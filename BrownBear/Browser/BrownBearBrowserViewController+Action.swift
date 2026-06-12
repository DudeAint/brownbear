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
            return
        }
        // No popup: the right destination (side panel / onClicked / options) depends on the extension's
        // manifest plus live chrome.sidePanel state, so resolve it off the main-actor store read.
        resolveNoPopupActionTap(extensionID: extensionID)
    }

    // MARK: - Helpers

    /// Present the extension's popup as a glassy popover anchored to the toolbar action button, so it
    /// floats over the page (Chrome/Safari-style) instead of covering it as a sheet. Internal so the
    /// extensions-toolbar hold-menu ("Open Popup") can reach it from its own +file.
    func presentActionPopup(extensionID: String) {
        Task { @MainActor in
            guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extensionID) else { return }
            let controller = WebExtensionPageViewController(ext: ext, kind: .popup)
            let anchor = toolbar.actionAnchorView
            present(controller.makePopover(sourceView: anchor, sourceRect: anchor.bounds), animated: true)
        }
    }

    /// Resolve a no-popup toolbar tap to the destination a user expects. Precedence (all after "no popup"):
    ///   1. side panel + setPanelBehavior({openPanelOnActionClick:true})  → open the side panel (Chrome)
    ///   2. a registered chrome.action.onClicked handler                  → deliver onClicked (Chrome)
    ///   3. a side panel (even without the behavior opt-in)               → open it — reachable on iOS,
    ///      which has no Chrome "puzzle menu" side-panel entry to open it from otherwise
    ///   4. an options page                                               → open it (configure-only ext)
    ///   5. none of the above                                             → deliver onClicked anyway (a
    ///      harmless no-op, matching Chrome, so behaviour is never worse than before)
    /// Async because the side-panel path + options page come from the extension's manifest (a store read).
    private func resolveNoPopupActionTap(extensionID: String) {
        let runtime = BrownBearServices.shared.webExtensionRuntime
        Task { @MainActor in
            guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extensionID) else { return }
            let panelPath = runtime.sidePanelPathOverride(extensionID: extensionID) ?? ext.manifest?.sidePanelPath
            let hasPanel = (panelPath?.isEmpty == false) && runtime.sidePanelEnabled(extensionID: extensionID)

            if hasPanel, runtime.sidePanelOpensOnActionClick(extensionID: extensionID) {
                presentSidePanel(ext: ext, path: panelPath)
                return
            }
            if runtime.hasActionClickedListener(extensionID: extensionID) {
                let tab = tabManager.activeTab.map(webExtActionTabRecord)
                runtime.fireActionClicked(extensionID: extensionID, tab: tab)
                return
            }
            if hasPanel {
                presentSidePanel(ext: ext, path: panelPath)
                return
            }
            if let options = ext.manifest?.optionsPage, !options.isEmpty {
                present(WebExtensionPageViewController(ext: ext, kind: .options).wrappedForPresentation(), animated: true)
                return
            }
            let tab = tabManager.activeTab.map(webExtActionTabRecord)
            runtime.fireActionClicked(extensionID: extensionID, tab: tab)
        }
    }

    /// chrome.sidePanel.open — present the extension's side-panel page (resolving the manifest default /
    /// setOptions override path) as a sheet over the page. iOS has no docked panel surface, so a sheet is
    /// the side-panel host; the page itself runs with the full chrome.* bridge like a popup/options page.
    func webExtPresentSidePanel(extensionID: String) {
        let runtime = BrownBearServices.shared.webExtensionRuntime
        Task { @MainActor in
            guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extensionID) else { return }
            let path = runtime.sidePanelPathOverride(extensionID: extensionID) ?? ext.manifest?.sidePanelPath
            presentSidePanel(ext: ext, path: path)
        }
    }

    /// Present an extension's side-panel page as a sheet, or no-op if it declares no side panel.
    private func presentSidePanel(ext: WebExtension, path: String?) {
        guard let path, !path.isEmpty else { return }
        let controller = WebExtensionPageViewController(ext: ext, kind: .sidebar, path: path)
        present(controller.wrappedForPresentation(), animated: true)
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
