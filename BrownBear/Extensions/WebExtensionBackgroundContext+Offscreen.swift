//
//  WebExtensionBackgroundContext+Offscreen.swift
//  BrownBear
//
//  The background worker's chrome.offscreen native (`__bb_offscreen`), split out of the main context
//  file (file-length limit). The worker (a DOM-less service worker) asks the native side to create /
//  query / close its single hidden offscreen document; the heavy lifting — a hidden WKWebView hosting
//  the real DOM — lives in WebExtensionOffscreenManager, reached through the runtime (the @MainActor
//  object that owns the view container and the document map). Mirrors the other install*Natives groups:
//  parse args, hop to the main actor, run the op, call back with a JSON result.
//
//  Members reached here (callBack / jsonString / extensionID) are internal on the context for exactly
//  this cross-file split.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// chrome.offscreen.{createDocument,hasDocument,closeDocument}. Each resolves to a JSON object the
    /// page-side shim interprets: `{}` (success), `{error}` (reject the Promise), or `{hasDocument}`.
    func installOffscreenNatives(into context: JSContext) {
        let extID = self.extensionID
        let offscreen: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let runtime = BrownBearServices.shared.webExtensionRuntime
                let result: [String: Any]
                switch method {
                case "createDocument":
                    let path = (args["url"] as? String) ?? ""
                    let reasons = (args["reasons"] as? [String]) ?? []
                    let justification = (args["justification"] as? String) ?? ""
                    result = await runtime.createOffscreenDocument(
                        extensionID: extID, path: path, reasons: reasons, justification: justification)
                case "hasDocument":
                    result = ["hasDocument": runtime.hasOffscreenDocument(extensionID: extID)]
                case "closeDocument":
                    result = runtime.closeOffscreenDocument(extensionID: extID)
                        ? [:] : ["error": "No offscreen document to close."]
                default:
                    result = ["error": "Unknown chrome.offscreen method."]
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(offscreen, forKeyedSubscript: "__bb_offscreen" as NSString)
    }
}
