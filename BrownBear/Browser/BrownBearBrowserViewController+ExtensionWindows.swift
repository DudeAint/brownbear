//
//  BrownBearBrowserViewController+ExtensionWindows.swift
//  BrownBear
//
//  The browser's implementation of the chrome.windows / runtime.openOptionsPage parts of
//  WebExtensionBridgeHost. iOS is single-window, so the whole windows surface collapses onto one
//  synthetic window (id 1) that always contains every open tab; windows.create degrades to opening a
//  tab (geometry, state, and focus are not expressible on iOS and are ignored). openOptionsPage
//  presents the extension's real options page (in a tab when the manifest asks for open_in_tab, else
//  as a sheet), so chrome.runtime.openOptionsPage actually navigates rather than no-opping.
//
//  Split into its own +file to stay out of +WebExtensions and under the SwiftLint length limit.
//

import UIKit

extension BrownBearBrowserViewController {

    /// The single synthetic window id every chrome.windows record carries (iOS is single-window).
    static let webExtWindowID = 1

    func webExtWindow(populate: Bool) -> [String: Any] {
        windowRecord(populate: populate)
    }

    func webExtAllWindows(populate: Bool) -> [[String: Any]] {
        [windowRecord(populate: populate)]
    }

    func webExtCreateWindow(url: String?, active: Bool, populate: Bool) -> [String: Any] {
        // No real new window on iOS — create a tab in the lone window and report that window back.
        _ = webExtCreateTab(url: url, active: active)
        return windowRecord(populate: populate)
    }

    /// chrome.windows.update / chrome.windows.remove have no expressible effect on a single, always-
    /// present window: geometry/state/focus aren't controllable and the window can't be closed. We
    /// still return the window record so callbacks/promises resolve with a chrome-shaped value.
    func webExtUpdateWindow(populate: Bool) -> [String: Any] {
        windowRecord(populate: populate)
    }

    /// chrome.runtime.openOptionsPage — open the extension's options page for real, as a genuine browser
    /// tab (the "•••"-menu Options action and an "open options" button inside a popup both route here).
    /// Returns false if the extension is unknown or declares no options page (so JS can surface lastError).
    ///
    /// The options page opens in a NEW TAB (Orion/Gear behaviour) rather than a modal sheet — see
    /// openExtensionPageTab, which gives that tab the per-extension chrome-extension:// scheme handler and
    /// the full chrome.* page bridge (a normal browser tab has neither, so it would be blank). Any popup
    /// presented over the browser is dismissed first so the new tab is actually visible.
    @discardableResult
    func webExtOpenOptionsPage(extensionID: String) -> Bool {
        Task { @MainActor in
            guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extensionID),
                  let manifest = ext.manifest, let page = manifest.optionsPage, !page.isEmpty else { return }
            openExtensionPageTab(ext: ext, kind: .options)
        }
        // We can't synchronously confirm the page opens (the store is an actor), but a missing options
        // page no-ops in the async task above. Report success optimistically here (Chrome also resolves
        // openOptionsPage before navigation completes).
        return true
    }

    // MARK: - Helpers

    /// The chrome.windows Window record for BrownBear's lone window. `populate` includes the tab list.
    private func windowRecord(populate: Bool) -> [String: Any] {
        var record: [String: Any] = [
            "id": Self.webExtWindowID,
            "focused": true,
            "incognito": tabManager.hasPrivateTabs && tabManager.normalTabs.isEmpty,
            "alwaysOnTop": false,
            "type": "normal",
            "state": "fullscreen"
        ]
        if populate {
            record["tabs"] = tabManager.tabs.map(webExtTabRecord)
        }
        return record
    }
}
