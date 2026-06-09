//
//  WebExtensionBackgroundContext+Platform.swift
//  BrownBear
//
//  Background-worker natives backed by iOS platform frameworks that don't fit the other groups:
//  chrome.i18n.detectLanguage (NaturalLanguage) and chrome.idle (UIApplication state). Split out of the
//  main context file (file-length limit). callBack/jsonString are internal on the context for this
//  cross-file split, and callBack hops to the context's serial queue itself, so these blocks may run
//  their (pure / main-actor) work off-queue and call back when done.
//

import Foundation
import JavaScriptCore
import NaturalLanguage
import UIKit

extension WebExtensionBackgroundContext {

    func installPlatformNatives(into context: JSContext) {
        // `new Image(); img.src = url` in the MV2 background → fetch the bytes natively and return a
        // `data:` URL (the JSContext can't decode pixels). Powers real script icons (Violentmonkey draws
        // the icon onto a canvas and toDataURL()s it, all in the background). SSRF-gated; off the queue.
        let fetchImage: @convention(block) (String, JSValue) -> Void = { [weak self] urlString, callback in
            guard let self else { return }
            let extID = self.extensionID
            Task.detached(priority: .utility) { [weak self] in
                let result = await WebExtensionImageBridge.fetchImageDataURL(urlString: urlString, extensionID: extID)
                guard let self else { return }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(fetchImage, forKeyedSubscript: "__bb_fetch_image" as NSString)

        // chrome.i18n.detectLanguage — NLLanguageRecognizer. CPU-bound and pure, so run it off the
        // worker's serial queue (Task.detached) and call back onto the queue with the result.
        let detect: @convention(block) (String, JSValue) -> Void = { [weak self] text, callback in
            guard let self else { return }
            Task.detached(priority: .utility) { [weak self] in
                let result = WebExtensionBackgroundContext.detectLanguages(in: text)
                guard let self else { return }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(detect, forKeyedSubscript: "__bb_i18n_detect" as NSString)

        // chrome.idle.queryState / setDetectionInterval. iOS can't observe global user input, so we map
        // app/device state: locked (data-protected) → "locked"; app foreground-active → "active"; else
        // "idle". setDetectionInterval is accepted (no true idle timer exists to tune).
        let idle: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, _, callback in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any
                switch method {
                case "queryState": result = WebExtensionBackgroundContext.currentIdleState()
                case "setDetectionInterval": result = NSNull()   // accepted; no tunable idle timer on iOS
                default: result = NSNull()
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(idle, forKeyedSubscript: "__bb_idle" as NSString)

        // chrome.tabs.captureVisibleTab — snapshot the active tab. Page pixels are sensitive (CLAUDE.md
        // §5), so we require a host_permissions match for the captured tab (this covers <all_urls>). We do
        // NOT honor bare "activeTab": Chrome only grants activeTab capture after a user gesture, which we
        // don't track — so we fail closed and require a declared host match. The gate runs INSIDE the host
        // capture (against the captured tab's URL) so a tab switch can't bypass it (TOCTOU). cookie*
        // are set once at boot, read-only after — capturing them for the closure is race-free.
        let permittedHosts = self.cookieHostMatcher
        let allUrls = self.cookiePermissions.contains("<all_urls>")
        let capture: @convention(block) (String, JSValue) -> Void = { [weak self] argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let format = (args["format"] as? String) ?? "png"
            let quality = (args["quality"] as? Int) ?? 92
            Task { @MainActor [weak self] in
                guard let self else { return }
                let dataURL = await self.host?.webExtCaptureVisibleTab(format: format, quality: quality) { url in
                    allUrls || (url.map { permittedHosts($0) } ?? false)
                }
                if let dataURL {
                    self.callBack(callback, with: self.jsonString(["dataUrl": dataURL]))
                } else {
                    self.callBack(callback, with: self.jsonString(
                        ["error": "captureVisibleTab needs a host permission matching the active tab"]))
                }
            }
        }
        context.setObject(capture, forKeyedSubscript: "__bb_capture_visible_tab" as NSString)

        // chrome.search.query — run a web search via the user's default search engine. No permission is
        // required (Chrome's chrome.search needs none); it just opens the results tab. Hop to the main
        // actor (TabManager) to open/navigate, then settle the JS promise.
        let search: @convention(block) (String, JSValue) -> Void = { [weak self] argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let text = (args["text"] as? String) ?? ""
            let disposition = args["disposition"] as? String
            let tabId = args["tabId"] as? Int
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.host?.webExtSearchQuery(text: text, disposition: disposition, extTabId: tabId)
                self.callBack(callback, with: self.jsonString(NSNull()))
            }
        }
        context.setObject(search, forKeyedSubscript: "__bb_search" as NSString)
    }

    /// Fire chrome.idle.onStateChanged into this worker. Called from the main actor (the runtime's app-
    /// lifecycle observers); hops to `queue` to touch the JSContext, like fireActionClicked.
    func fireIdleStateChanged(_ state: String) {
        queue.async { [weak self] in
            self?.fire(method: "dispatchIdleStateChanged", arguments: [state])
        }
    }

    /// The chrome.idle state for the current app/device condition.
    @MainActor
    static func currentIdleState() -> String {
        if !UIApplication.shared.isProtectedDataAvailable { return "locked" }
        return UIApplication.shared.applicationState == .active ? "active" : "idle"
    }

    /// chrome.i18n.detectLanguage result: the dominant languages of `text` with integer confidence
    /// percentages (sorted desc), mirroring Chrome's CLD shape. `isReliable` when the top language is
    /// at least moderately confident. Empty/whitespace input → not reliable, no languages.
    nonisolated static func detectLanguages(in text: String) -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["isReliable": false, "languages": []] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        guard !hypotheses.isEmpty else { return ["isReliable": false, "languages": []] }
        let sorted = hypotheses.sorted { $0.value > $1.value }
        let languages: [[String: Any]] = sorted.map {
            ["language": $0.key.rawValue, "percentage": Int(($0.value * 100).rounded())]
        }
        let isReliable = (sorted.first?.value ?? 0) >= 0.5
        return ["isReliable": isReliable, "languages": languages]
    }
}
