//
//  WebExtensionBackgroundContext+Downloads.swift
//  BrownBear
//
//  The background worker's chrome.downloads native (`__bb_downloads`) + the onCreated/onChanged/onErased
//  delivery into the worker. The transfer + record-keeping live in WebExtensionDownloadsManager (reached
//  through the runtime); this is the per-worker bridge: gate on the "downloads" permission, hop to the
//  main actor, run the op, call back. Split out of the main context file (file-length limit).
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    func installDownloadsNatives(into context: JSContext) {
        let extID = self.extensionID
        let downloads: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            // Permission gate on the serial queue (cookiePermissions is set once at boot, read-only after).
            let hasPermission = self.cookiePermissions.contains("downloads")
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard hasPermission else {
                    self.callBack(callback, with: self.jsonString(["error": "The 'downloads' permission is required."]))
                    return
                }
                let runtime = BrownBearServices.shared.webExtensionRuntime
                let id = args["id"] as? Int ?? -1
                let result: [String: Any]
                switch method {
                case "download": result = runtime.downloadsDownload(extensionID: extID, options: args)
                case "search": result = ["items": runtime.downloadsSearch(extensionID: extID, query: args)]
                case "cancel": result = ["ok": runtime.downloadsCancel(extensionID: extID, id: id)]
                case "pause": result = ["ok": runtime.downloadsPause(extensionID: extID, id: id)]
                case "resume": result = ["ok": runtime.downloadsResume(extensionID: extID, id: id)]
                case "erase": result = ["erased": runtime.downloadsErase(extensionID: extID, query: args)]
                case "removeFile": result = ["ok": runtime.downloadsRemoveFile(extensionID: extID, id: id)]
                default: result = ["error": "Unsupported chrome.downloads method."]
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(downloads, forKeyedSubscript: "__bb_downloads" as NSString)
    }

    /// Deliver a chrome.downloads event (onCreated/onChanged/onErased) into this worker. `payload` is a
    /// pre-serialized JSON string. Hops to `queue` to touch the JSContext, like fireIdleStateChanged.
    func fireDownloadEvent(kind: String, payload: String) {
        queue.async { [weak self] in
            self?.fire(method: "dispatchDownloadEvent", arguments: [kind, payload])
        }
    }
}
