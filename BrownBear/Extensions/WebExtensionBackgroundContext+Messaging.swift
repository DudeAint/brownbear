//
//  WebExtensionBackgroundContext+Messaging.swift
//  BrownBear
//
//  The background worker's runtime/tabs MESSAGING natives, split out of the main context file
//  (file-length limit). These bridge chrome.runtime.sendMessage / sendResponse and
//  chrome.tabs.sendMessage between the worker's JSContext and the native side, plus the chrome.tabs
//  dispatcher. All closures run on the context's serial `queue` (or hop to the main actor where a
//  TabManager-backed host op needs it), then call back with a JSON result — the same pattern as the
//  other install*Natives groups. Members reached here (callBack/jsonString/extensionID/host/
//  resolveResponse) are internal on the context for exactly this cross-file split.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// The runtime/tabs MESSAGING natives: the worker sending a runtime message, answering a content
    /// script's pushed message (resolving a parked continuation), and chrome.tabs.sendMessage out to a
    /// tab's content scripts. Grouped so installNatives stays readable as the surface grows.
    func installMessagingNatives(into context: JSContext) {
        // background chrome.runtime.sendMessage → the extension's PAGES (popup / options / offscreen
        // document). Chrome delivers a worker's broadcast to every other context of the extension; on
        // iOS there's only one worker per extension, so we fan out to the live pages (senderIsBackground
        // skips re-delivering to this same worker) and return the first responder's `{value}`. This is
        // what makes chrome.offscreen useful: the worker posts work to its offscreen document and awaits
        // the reply. Content scripts receive via tabs.sendMessage, not this fan-out.
        let extID = self.extensionID
        let sendMessage: @convention(block) (String, JSValue) -> Void = { [weak self] payloadJSON, callback in
            guard let self else { return }
            let parsed = ((try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))) as? [String: Any]) ?? [:]
            let message = parsed["message"] ?? NSNull()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = await BrownBearServices.shared.webExtensionRuntime.sendRuntimeMessage(
                    message, sender: ["id": extID], to: extID, senderIsBackground: true)
                // Three outcomes, mirroring Chrome: a real responder replies `{value:…}`; NO context had
                // a listener → pass `{__bbNoReceiver}` through so the JS sets lastError / rejects the
                // Promise; nil (received but declined/no answer) → null → resolves undefined, no error.
                if let response, response["__bbNoReceiver"] == nil {
                    self.callBack(callback, with: self.jsonString(response))
                } else if response?["__bbNoReceiver"] != nil {
                    self.callBack(callback, with: self.jsonString(["__bbNoReceiver": true]))
                } else {
                    self.callBack(callback, with: "null")
                }
            }
        }
        context.setObject(sendMessage, forKeyedSubscript: "__bb_send_message" as NSString)

        // A content/popup message the worker is answering: resolve the parked continuation by id.
        let messageResponse: @convention(block) (String, JSValue?) -> Void = { [weak self] responseId, payload in
            guard let self else { return }
            // Already on `queue` (JS called us). Normalize payload to a Swift dict or nil.
            var dict: [String: Any]?
            if let payload, !payload.isUndefined, !payload.isNull,
               let string = payload.toString(),
               let data = string.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict = object
            }
            self.resolveResponse(responseId, payload: dict)
        }
        context.setObject(messageResponse, forKeyedSubscript: "__bb_message_response" as NSString)

        // chrome.tabs.sendMessage from the background worker → a tab's content scripts. Hops to the
        // main actor, delivers through the bridge host (which routes to the content router that owns the
        // tab's sessions), and calls back with the first content listener's response wrapped as {value}.
        let tabsSendMessage: @convention(block) (String, JSValue) -> Void = { [weak self] argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let extID = self.extensionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                let response: Any? = await self.host?.webExtSendMessageToTab(
                    extensionID: extID,
                    extTabId: args["tabId"] as? Int,
                    message: args["message"] ?? NSNull(),
                    frameId: args["frameId"] as? Int)
                self.callBack(callback, with: self.jsonString(["value": response ?? NSNull()]))
            }
        }
        context.setObject(tabsSendMessage, forKeyedSubscript: "__bb_tabs_send_message" as NSString)
    }

    /// Map a chrome.tabs method + args to the bridge host, returning a JSON-serializable value.
    @MainActor
    static func dispatchTab(host: WebExtensionBridgeHost, method: String, args: [String: Any]) -> Any {
        switch method {
        case "query":
            return host.webExtQueryTabs(args["query"] as? [String: Any] ?? [:])
        case "get":
            return host.webExtTab(extTabId: args["tabId"] as? Int) ?? NSNull()
        case "create":
            return host.webExtCreateTab(url: args["url"] as? String, active: (args["active"] as? Bool) ?? true)
        case "update":
            return host.webExtUpdateTab(extTabId: args["tabId"] as? Int,
                                        url: args["url"] as? String,
                                        active: args["active"] as? Bool) ?? NSNull()
        case "remove":
            let ids = (args["tabIds"] as? [Int]) ?? (args["tabId"] as? Int).map { [$0] } ?? []
            host.webExtRemoveTabs(extTabIds: ids)
            return NSNull()
        case "reload":
            host.webExtReloadTab(extTabId: args["tabId"] as? Int, bypassCache: (args["bypassCache"] as? Bool) ?? false)
            return NSNull()
        default:
            return NSNull()   // getCurrent et al. — undefined in a background worker
        }
    }
}
