//
//  BrownBearBrowserViewController+ContextMenus.swift
//  BrownBear
//
//  Surfaces extension chrome.contextMenus items in WebKit's element long-press menu — iOS has no
//  persistent toolbar/right-click menu, so this is the only place they can appear. We implement the
//  WKUIDelegate element-menu hook (the protocol conformance itself is declared in the main file, so
//  this is a plain extension adding one witness) and APPEND the applicable items to WebKit's own
//  suggested actions, preserving Open/Copy/Share.
//
//  Contexts on iOS reduce to page (always) and link (when long-pressing a link — the only field
//  WKContextMenuElementInfo exposes). selection/editable/image/etc. can't be detected, so items
//  scoped only to those never match. A tap builds OnClickData, applies the checkbox/radio state
//  change, and fires chrome.contextMenus.onClicked into the extension's background worker.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController {

    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        let linkURL = elementInfo.linkURL?.absoluteString
        let pageURL = tabManager.activeTab?.state.url?.absoluteString ?? webView.url?.absoluteString ?? ""
        var available: Set<String> = ["page"]
        if linkURL?.isEmpty == false { available.insert("link") }

        let store = BrownBearServices.shared.webExtensionContextMenuStore
        var extensionMenus: [UIMenuElement] = []
        for extensionID in store.extensionIDsWithItems() {
            let tree = store.applicableTree(extensionID: extensionID, pageURL: pageURL,
                                            linkURL: linkURL, contexts: available)
            extensionMenus.append(contentsOf: tree.compactMap {
                makeMenuElement($0, extensionID: extensionID, pageURL: pageURL, linkURL: linkURL)
            })
        }
        guard !extensionMenus.isEmpty else {
            completionHandler(nil)   // nothing to add — leave WebKit's default menu untouched
            return
        }
        // An inline group so the extension items read as their own section beneath WebKit's actions.
        let extensionGroup = UIMenu(title: "", options: .displayInline, children: extensionMenus)
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggestedActions in
            UIMenu(title: "", children: suggestedActions + [extensionGroup])
        }
        completionHandler(config)
    }

    /// Turn one resolved item (and its applicable children) into a UIAction / submenu. Separators are
    /// omitted (UIMenu has no separator element); disabled items render dimmed; checkbox/radio show a
    /// checkmark via `.on`.
    private func makeMenuElement(_ resolved: WebExtensionContextMenuStore.ResolvedItem,
                                 extensionID: String, pageURL: String, linkURL: String?) -> UIMenuElement? {
        let item = resolved.item
        if item.type == .separator { return nil }
        if !resolved.children.isEmpty {
            let children = resolved.children.compactMap {
                makeMenuElement($0, extensionID: extensionID, pageURL: pageURL, linkURL: linkURL)
            }
            guard !children.isEmpty else { return nil }
            return UIMenu(title: item.title, children: children)
        }
        var attributes: UIMenuElement.Attributes = []
        if !item.enabled { attributes.insert(.disabled) }
        let state: UIMenuElement.State =
            (item.type == .checkbox || item.type == .radio) && item.checked ? .on : .off
        return UIAction(title: item.title, attributes: attributes, state: state) { [weak self] _ in
            self?.dispatchContextMenuClick(extensionID: extensionID, itemID: item.id,
                                           pageURL: pageURL, linkURL: linkURL)
        }
    }

    /// A tap fired the item: build OnClickData from the pre-tap state, apply the checkbox/radio change,
    /// then deliver chrome.contextMenus.onClicked to the worker with the active tab's record.
    private func dispatchContextMenuClick(extensionID: String, itemID: String,
                                          pageURL: String, linkURL: String?) {
        let store = BrownBearServices.shared.webExtensionContextMenuStore
        guard let item = store.item(extensionID: extensionID, id: itemID) else { return }
        let info = store.onClickData(item: item, pageURL: pageURL, linkURL: linkURL)
        store.applyClickStateChange(extensionID: extensionID, id: itemID)
        let tab = tabManager.activeTab.map { webExtTabRecord($0) }
        BrownBearServices.shared.webExtensionRuntime.fireContextMenuClicked(
            extensionID: extensionID, info: info, tab: tab)
    }
}
