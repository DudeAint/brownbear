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

        // chrome.tabs.captureVisibleTab — snapshot the active tab. Gated like cookies: the extension needs
        // "activeTab", host_permissions matching the active tab, or <all_urls> (page pixels are sensitive,
        // CLAUDE.md §5). cookiePermissions/cookieHostMatcher are set once at boot, read-only thereafter, so
        // reading them on the main actor is race-free (same pattern as cookiePermitted).
        let capture: @convention(block) (String, JSValue) -> Void = { [weak self] argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let format = (args["format"] as? String) ?? "png"
            let quality = (args["quality"] as? Int) ?? 92
            Task { @MainActor [weak self] in
                guard let self else { return }
                let activeURL = self.host?.webExtActiveTabURLString()
                let permitted = self.cookiePermissions.contains("activeTab")
                    || self.cookiePermissions.contains("<all_urls>")
                    || (activeURL.map { self.cookieHostMatcher($0) } ?? false)
                guard permitted else {
                    self.callBack(callback, with: self.jsonString(
                        ["error": "captureVisibleTab requires the 'activeTab' or matching host permission"]))
                    return
                }
                let dataURL = await self.host?.webExtCaptureVisibleTab(format: format, quality: quality)
                if let dataURL {
                    self.callBack(callback, with: self.jsonString(["dataUrl": dataURL]))
                } else {
                    self.callBack(callback, with: self.jsonString(["error": "no capturable tab"]))
                }
            }
        }
        context.setObject(capture, forKeyedSubscript: "__bb_capture_visible_tab" as NSString)
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
