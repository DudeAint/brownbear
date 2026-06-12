//
//  WebExtensionBackgroundContext+SidePanel.swift
//  BrownBear
//
//  The native bridge behind chrome.sidePanel (MV3) / sidebar_action (Firefox). The worker calls
//  __bb_sidepanel(method, argsJSON, cb); this hops to the main actor and drives WebExtensionRuntime's
//  per-extension side-panel state (path override + enabled + openPanelOnActionClick) and, for open(),
//  asks the live browser to present the side-panel page (hosted as a sheet on iOS — there's no docked
//  panel surface). Split into its own +file so the main context file stays under the length limit;
//  `extensionID`/`callBack`/`jsonString` are internal so this extension can reach them.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// Register __bb_sidepanel — the chrome.sidePanel surface. Mirrors installActionNatives: parse the
    /// args, hop to the @MainActor runtime, and call back with the JSON result (NSNull for the void
    /// setters / open; the options/behavior objects for the getters).
    func installSidePanelNatives(into context: JSContext) {
        let sidePanel: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let extensionID = self.extensionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                let runtime = BrownBearServices.shared.webExtensionRuntime
                var result: Any = NSNull()
                switch method {
                case "open":
                    runtime.presentSidePanel(extensionID: extensionID)
                case "setOptions":
                    runtime.setSidePanelOptions(extensionID: extensionID,
                                                path: args["path"] as? String,
                                                enabled: args["enabled"] as? Bool)
                case "getOptions":
                    result = runtime.sidePanelOptions(extensionID: extensionID)
                case "setPanelBehavior":
                    runtime.setSidePanelBehavior(extensionID: extensionID,
                                                 openOnActionClick: (args["openPanelOnActionClick"] as? Bool) ?? false)
                case "getPanelBehavior":
                    result = runtime.sidePanelBehavior(extensionID: extensionID)
                default:
                    break
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(sidePanel, forKeyedSubscript: "__bb_sidepanel" as NSString)
    }
}
