//
//  WebExtensionBackgroundContext.swift
//  BrownBear
//
//  One extension's BACKGROUND execution context: a long-lived JavaScriptCore JSContext that runs an
//  MV2 background script or an MV3 service worker headless, with a native-backed chrome.* surface
//  (storage, alarms, runtime messaging, i18n) provided by `brownbear-webext-background.js`.
//
//  Threading: the JSContext is NOT thread-safe, so EVERY interaction with it happens on this
//  object's private serial `queue`. Native blocks are invoked by JS (so already on `queue`); async
//  results from the storage actor and incoming messages from the main actor are funnelled back onto
//  `queue` before they ever touch a JSValue. `@unchecked Sendable` is the contract that we uphold
//  that discipline ourselves.
//

import CryptoKit
import Foundation
import JavaScriptCore

final class WebExtensionBackgroundContext: @unchecked Sendable {

    let extensionID: String
    private let extensionName: String
    private let storage: WebExtensionStorage
    let logSink: @Sendable (LogEntry) -> Void
    /// chrome.tabs bridge to the browser, set by WebExtensionRuntime. Every use hops to the main actor
    /// (the native block runs on this context's serial queue; tab ops are MainActor/UIKit).
    weak var host: WebExtensionBridgeHost?
    /// chrome.cookies bridge to the browser, set by WebExtensionRuntime (same lifecycle as host).
    weak var cookieHost: WebExtensionCookieBridgeHost?
    /// This extension's `cookies`-gate inputs, captured at boot: the declared permissions and a pure
    /// host-pattern matcher. Set ONCE in boot (on `queue`) before any native can fire; thereafter
    /// read-only, so the cross-actor read in `cookiePermitted` (on the main actor) is race-free.
    var cookiePermissions: Set<String> = []
    var cookieHostMatcher: (String) -> Bool = { _ in false }
    /// The raw host_permission patterns (same source as `cookieHostMatcher`), kept so the fetch path can
    /// build a redirect-guard that re-applies the gate to 3xx targets (SSRF). Set once in boot.
    var cookieHostPatterns: [String] = []
    /// Granted API permissions, cached by the runtime at boot. Defense-in-depth for event gating (the
    /// authoritative webNavigation gate lives in WebExtensionRuntime.dispatchEventToAll). On `queue`.
    private var grantedPermissions: Set<String> = []

    // Internal (not private) so +Platform's fireIdleStateChanged can hop onto it. Serial; every JSContext
    // touch happens here.
    let queue: DispatchQueue
    /// Internal (not private) so +Crypto's importScripts shim can evaluate a loaded chunk in this
    /// worker's GLOBAL scope (shared lexical env), like importScripts in a real service worker.
    var context: JSContext?
    // Internal (not private) so +ServiceWorkerFetch can gate its queue hop on a live context.
    var isAlive = true

    // Pending content→background message replies, keyed by a per-context response id.
    private var pendingResponses: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
    // The intent label (e.g. "(gmApi)") of each pending reply, so resolveResponse can report WHAT the
    // worker answered and with how much payload — turning a silent "deferred" into a diagnosable result
    // (a ScriptCat GM_xmlhttpRequest whose 200 reply comes back empty/null vs full is invisible otherwise).
    private var pendingResponseLabels: [String: String] = [:]
    private var responseCounter = 0
    // Parked SW fetch-event results by request id; resolved by __bb_sw_fetch_response (+ServiceWorkerFetch).
    var pendingServiceWorkerFetch: [String: CheckedContinuation<ServiceWorkerFetchResponse?, Never>] = [:]
    var serviceWorkerFetchCounter = 0

    // chrome.alarms — in-memory, foreground-lifetime GCD timers.
    private struct AlarmState { var scheduledTime: Double; var periodInMinutes: Double }
    private var alarms: [String: AlarmState] = [:]
    private var alarmTimers: [String: DispatchSourceTimer] = [:]

    // setTimeout / setInterval registry.
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var timerCounter = 0
    // Pending setTimeout(fn, 0) one-shots dispatched via queue.async (not a DispatchSourceTimer). Removed
    // when they fire or are cleared; an id absent here when its block runs means clearTimeout cancelled it.
    private var pendingZeroDelay: Set<Int> = []

    init(extensionID: String,
         extensionName: String,
         storage: WebExtensionStorage,
         logSink: @escaping @Sendable (LogEntry) -> Void) {
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.storage = storage
        self.logSink = logSink
        self.queue = DispatchQueue(label: "com.brownbear.webext.bg.\(extensionID)")
    }

    // MARK: - Lifecycle

    /// Boot the context: install the native bridge, evaluate the chrome.* runtime, then the
    /// extension's own background source, then fire onInstalled/onStartup.
    /// `moduleEntry`/`esmRuntimeJS`/`moduleSource` are non-nil only for an MV3 `"type":"module"`
    /// service worker. JSC ships no ES-module loader, so instead of evaluating `backgroundSource` as
    /// a classic script we evaluate the ESM linker runtime (acorn + brownbear-esm-linker) and let it
    /// resolve and run the entry module's graph from the package via `moduleSource` — see
    /// runModuleWorker. `moduleSource` is a `@Sendable` synchronous reader (the store actor's
    /// `nonisolated fileSync`), safe to call on this context's serial queue.
    func boot(runtimeJS: String, backgroundSource: String,
              manifestJSON: String, baseURL: String, messages: [String: String],
              placeholders: [String: [String: String]] = [:],
              installReason: String? = nil, previousVersion: String? = nil,
              moduleEntry: String? = nil, esmRuntimeJS: String? = nil,
              moduleSource: (@Sendable (String) -> Data?)? = nil) {
        queue.async { [self] in
            guard let context = JSContext() else {
                logSink(makeLog(.error, "could not create a background JS context"))
                return
            }
            self.context = context

            context.exceptionHandler = { [weak self] _, value in
                guard let self else { return }
                var message = "uncaught: \(value?.toString() ?? "unknown exception")"
                // JSC error values carry a `.stack`; toString() alone drops it (the same class as the
                // content-side JSC-omits-the-stack gap). Append it so a background throw is pinpointable.
                if let stack = value?.objectForKeyedSubscript("stack")?.toString(),
                   !stack.isEmpty, stack != "undefined" {
                    message += "\n\(stack)"
                }
                self.logSink(self.makeLog(.error, message))
            }

            installNatives(into: context)

            // Capture the cookie gate (permissions + host matcher) once, on `queue`, before any native
            // can fire. Pure value work — safe off the main actor.
            if let json = (try? JSONSerialization.jsonObject(with: Data(manifestJSON.utf8))) as? [String: Any],
               let parsed = try? WebExtensionManifest.parse(json) {
                cookiePermissions = Set(parsed.permissions)
                // host_permissions ONLY — content_scripts.matches is not host access (Chrome). The
                // worker's chrome.cookies/fetch gate must not be widened by a content-script match.
                let matcher = URLMatcher(matches: parsed.hostPermissions,
                                         includes: [], excludes: [], excludeMatches: [])
                cookieHostMatcher = { matcher.matches($0) }
                cookieHostPatterns = parsed.hostPermissions
            }

            // Configuration globals the runtime reads on load.
            context.setObject(manifestJSON, forKeyedSubscript: "__bbBgManifest" as NSString)
            context.setObject(extensionID, forKeyedSubscript: "__bbBgExtId" as NSString)
            context.setObject(baseURL, forKeyedSubscript: "__bbBgBaseURL" as NSString)
            let messagesJSON = jsonString(messages)
            context.setObject(messagesJSON, forKeyedSubscript: "__bbBgMessages" as NSString)
            // Named-placeholder map for chrome.i18n.getMessage (messageKey → {name: content}); the flat
            // message map above drops it, leaking literal `$version$` tokens without this.
            context.setObject(jsonString(placeholders), forKeyedSubscript: "__bbBgPlaceholders" as NSString)
            // Device-derived inputs for the navigator polyfill (JSC has no DOM; see HeadlessEnvironment).
            context.setObject(HeadlessEnvironment.userAgent, forKeyedSubscript: "__bbUserAgent" as NSString)
            context.setObject(HeadlessEnvironment.language, forKeyedSubscript: "__bbLanguage" as NSString)
            // IndexedDB engine first (so `indexedDB` exists), then the runtime (which defines the web
            // globals — Blob/File/FileReader — the engine's structured-clone needs), THEN rehydrate the
            // snapshot: replaying it before Blob/File exist would revive a persisted Blob as a raw
            // tagged record. All three happen before the background/module source runs.
            BrownBearIDBStore.shared.install(into: context, namespace: .ext(extensionID), rehydrate: false)
            context.evaluateScript(runtimeJS, withSourceURL: URL(string: "brownbear://webext/\(extensionID)/runtime.js"))
            logSink(makeLog(.debug, "[bb-bg] runtime shim + IndexedDB ready; evaluating background source"))
            BrownBearIDBStore.shared.rehydrate(into: context, namespace: .ext(extensionID))
            if let moduleEntry, let esmRuntimeJS, let moduleSource {
                // An MV2 background PAGE (uBlock Origin's background.html) can carry classic <script>s
                // BEFORE its module entry (lz4 codec, vapi.js before start.js). Evaluate them first, in
                // document order — exactly the load order the page's HTML parser would give — then link
                // the module graph. MV3 module workers pass an empty source, so nothing changes for them.
                if !backgroundSource.isEmpty {
                    let preludeURL = URL(string: "brownbear://webext/\(extensionID)/background-prelude.js")
                    context.evaluateScript(backgroundSource, withSourceURL: preludeURL)
                    context.exception = nil   // a prelude throw is logged by the handler; don't bleed into the link
                }
                // MV3 module service worker (or an MV2 page's module entry): link the graph in-context.
                runModuleWorker(in: context, esmRuntimeJS: esmRuntimeJS,
                                entryPath: moduleEntry, moduleSource: moduleSource)
            } else {
                // Evaluate the classic SW at GLOBAL scope, exactly like Chrome: top-level `var` /
                // `function` declarations must become GLOBALS so they're visible across importScripts()
                // chunks and to later code that references them as globals. Wrapping the source in an
                // IIFE made those declarations closure-local, which broke real bundles whose chunks
                // share top-level symbols (Violentmonkey's `M`, Best AdBlocker's `fn`). Only if the
                // source is a non-Chrome bundle with a bare top-level `return` (a SyntaxError at global
                // scope) do we retry inside a function wrapper.
                let bgURL = URL(string: "brownbear://webext/\(extensionID)/background.js")
                context.evaluateScript(backgroundSource, withSourceURL: bgURL)
                if let exception = context.exception {
                    context.exception = nil   // clear so it can't bleed into the onInstalled/onStartup fires
                    // A bare top-level `return` is a SyntaxError at global scope (some non-Chrome bundles
                    // do this). Only then retry inside a function wrapper; a genuine runtime error was
                    // already logged by the exceptionHandler and must NOT be re-run.
                    if (exception.toString() ?? "").localizedCaseInsensitiveContains("return statement") {
                        context.evaluateScript("(function(){" + backgroundSource + "\n})();", withSourceURL: bgURL)
                    }
                }
            }
            // DIAGNOSTIC: report that the background source finished its SYNCHRONOUS evaluation, and that
            // chrome.* is wired. Most managers then do ASYNC init (load their tree from IndexedDB, register
            // onMessage). If the popup later logs "no __bbBg dispatcher" or "NEVER responded", that async
            // init is what stalled — which pins the global blank-popup / "unable to load tree" symptom.
            let chromeReady = context.evaluateScript(
                "(function(){try{return !!(globalThis.chrome&&globalThis.chrome.runtime);}catch(e){return false;}})()"
            )?.toBool() ?? false
            logSink(makeLog(.debug, "[bb-bg] background source evaluated (chrome.runtime ready: \(chromeReady)); "
                + "async init now running"))

            // onInstalled fires with reason 'install' on the first-ever boot and 'update' (carrying the
            // previousVersion) when this id boots at a new version — the Chrome contract; `installReason`
            // is nil on a same-version reboot so first-run setup doesn't re-run. onStartup fires always.
            if let installReason {
                var args: [Any] = [installReason]
                if let previousVersion { args.append(previousVersion) }
                fire(method: "fireInstalled", arguments: args)
            }
            fire(method: "fireStartup", arguments: [])
        }
    }

    func shutdown() {
        queue.async { [self] in
            isAlive = false
            BrownBearIDBStore.shared.flush(context: context)   // persist any writes before timers die
            for timer in alarmTimers.values { timer.cancel() }
            for timer in timers.values { timer.cancel() }
            alarmTimers.removeAll()
            timers.removeAll()
            pendingZeroDelay.removeAll()   // queued setTimeout(0) blocks check isAlive and no-op anyway
            alarms.removeAll()
            // Resolve anything still waiting so callers never hang.
            for (_, continuation) in pendingResponses { continuation.resume(returning: nil) }
            pendingResponses.removeAll()
            pendingResponseLabels.removeAll()
            context = nil
        }
    }

    // MARK: - Inbound events (called from the main actor)

    /// Deliver a content-script message to this extension's runtime.onMessage listeners and await
    /// the (possibly async) sendResponse. Resolves to `["value": ...]`, or nil if nothing answered.
    func deliverRuntimeMessage(message: Any, sender: [String: Any]) async -> [String: Any]? {
        await deliverMessage(dispatch: "dispatchMessage", message: message, sender: sender)
    }

    /// Deliver a USER_SCRIPT-world script's message to chrome.runtime.onUserScriptMessage (the MV3 User
    /// Scripts channel), awaiting its (possibly async) sendResponse. Same shape as deliverRuntimeMessage.
    func fireUserScriptMessage(message: Any, sender: [String: Any]) async -> [String: Any]? {
        await deliverMessage(dispatch: "dispatchUserScriptMessage", message: message, sender: sender)
    }

    /// Shared plumbing: invoke a `__bbBg` dispatcher with (message, sender, responseId), park a
    /// continuation keyed by responseId, and resolve it on sendResponse (or a 30s timeout).
    private func deliverMessage(dispatch method: String, message: Any, sender: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            queue.async { [self] in
                guard isAlive, let context else { continuation.resume(returning: nil); return }
                responseCounter += 1
                let responseId = "r\(responseCounter)"
                pendingResponses[responseId] = continuation
                pendingResponseLabels[responseId] = Self.messageLabel(message)

                let messageJSON = jsonString(message)
                let senderJSON = jsonString(sender)
                // A short label naming THIS message's intent — managers tag their RPC with `method`
                // (Tampermonkey: loadTree/saveScript/…), others with what/cmd/type/action. Without it the
                // diagnostic only says "dispatchMessage", so a request that's RECEIVED but answered with an
                // empty/null reply (Tampermonkey saving a script that never appears) can't be told apart
                // from one that worked. Surface it so the device log pins the exact failing call.
                let msgLabel = Self.messageLabel(message)
                if let dispatcher = context.objectForKeyedSubscript("__bbBg"),
                   !dispatcher.isUndefined {
                    dispatcher.invokeMethod(method, withArguments: [messageJSON, senderJSON, responseId])
                    // DIAGNOSTIC (the global "popup blank / unable to load tree" hunt): a popup's first
                    // ping (e.g. Tampermonkey's init) blanks the popup if the background never replies.
                    // After invoking the dispatcher, the continuation is gone iff a listener answered
                    // synchronously; still parked means a listener returned true (will sendResponse later)
                    // or NO listener ran at all. Name which, so the device log pins where the bg stalls.
                    if pendingResponses[responseId] == nil {
                        logSink(makeLog(.debug, "[bb-bg] \(method)\(msgLabel) answered synchronously"))
                    } else {
                        logSink(makeLog(.debug, "[bb-bg] \(method)\(msgLabel) deferred — a listener will sendResponse, or none ran; awaiting reply"))
                    }
                } else {
                    logSink(makeLog(.warn, "[bb-bg] \(method)\(msgLabel): no __bbBg dispatcher — background never finished init "
                        + "(stalled before registering onMessage). The popup/dashboard will hang/blank waiting on it."))
                    resolveResponse(responseId, payload: nil)
                    return
                }

                // Don't leak a continuation if a listener returns `true` then never responds.
                queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self else { return }
                    if self.pendingResponses[responseId] != nil {
                        self.logSink(self.makeLog(.warn, "[bb-bg] \(method)\(msgLabel) NEVER responded within 30s — the onMessage "
                            + "handler stalled (its async work, e.g. an IndexedDB read, never completed). This is the "
                            + "root of the blank popup / 'unable to load tree'."))
                    }
                    self.resolveResponse(responseId, payload: nil)
                }
            }
        }
    }

    /// A short `(intent)` tag for a runtime message, for the dispatch diagnostic — managers carry their
    /// RPC name under `method` (Tampermonkey: loadTree/saveScript), others under what/cmd/type/action.
    /// Returns `""` when none is present (a bare data message) so the log line stays clean. Capped so a
    /// hostile/huge field can't bloat the log.
    static func messageLabel(_ message: Any) -> String {
        guard let dict = message as? [String: Any] else { return "" }
        for key in ["method", "what", "cmd", "type", "action"] {
            if let value = dict[key] as? String, !value.isEmpty {
                return "(\(value.prefix(48)))"
            }
        }
        return ""
    }

    /// Fire chrome.storage.onChanged for a change set originating anywhere.
    func dispatchStorageChanged(area: String, changes: [String: [String: String]]) {
        let changesJSON = jsonString(changes)
        queue.async { [self] in
            fire(method: "dispatchStorageChanged", arguments: [area, changesJSON])
        }
    }

    /// Cache this worker's granted permissions (runtime sets them right after boot). Defense-in-depth:
    /// the authoritative webNavigation event gate is in WebExtensionRuntime.dispatchEventToAll.
    func setGrantedPermissions(_ permissions: Set<String>) {
        queue.async { [self] in self.grantedPermissions = permissions }
    }

    /// Fire a browser-pushed chrome.tabs.* / chrome.webNavigation.* event into this worker. `argsJSON`
    /// is a JSON array of the event arguments (encoded on the main actor); the JS dispatcher parses
    /// and applies it on this context's serial queue, never touching a JSValue off-thread.
    func dispatchExtEvent(name: String, argsJSON: String) {
        queue.async { [self] in
            fire(method: "dispatchExtEvent", arguments: [name, argsJSON])
        }
    }

    // MARK: - Native bridge (all invoked on `queue`)

    private func installNatives(into context: JSContext) {
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            guard let self else { return }
            self.logSink(self.makeLog(LogEntry.Level(rawValue: level) ?? .info, message))
        }
        context.setObject(log, forKeyedSubscript: "__bb_log" as NSString)

        // The worker flags itself the first time a (non-userscript) blocking webRequest.onBeforeRequest
        // listener registers, so the navigation delegate consults it on frame loads (the only request class
        // WKWebView lets us intercept) instead of paying that cost for every extension.
        let extID = extensionID
        let noteBlockingWR: @convention(block) () -> Void = {
            Task { @MainActor in BrownBearServices.shared.webExtensionRuntime.noteBlockingWebRequest(extensionID: extID) }
        }
        context.setObject(noteBlockingWR, forKeyedSubscript: "__bb_note_blocking_webrequest" as NSString)

        // The worker flags itself the first time an action/pageAction.onClicked listener registers, so the
        // toolbar-tap path can tell a click-handling extension from a configure-only one: a no-popup action
        // with no onClicked handler opens the extension's options page instead of firing a click into the void.
        let noteActionClicked: @convention(block) () -> Void = {
            Task { @MainActor in BrownBearServices.shared.webExtensionRuntime.noteActionClickedListener(extensionID: extID) }
        }
        context.setObject(noteActionClicked, forKeyedSubscript: "__bb_note_action_onclicked" as NSString)

        installStorageNatives(into: context)
        installAlarmNatives(into: context)
        installTimerNatives(into: context)
        installMessagingNatives(into: context)
        installCookiesNatives(into: context)
        installNotificationNatives(into: context)
        installActionNatives(into: context)
        installSidePanelNatives(into: context)
        installWindowsManagementPermissionsNatives(into: context)
        installDNRAndUserScriptNatives(into: context)
        installCryptoNatives(into: context)
        installFetchNative(into: context)
        installContextMenuNatives(into: context)
        installPortNatives(into: context)
        installOffscreenNatives(into: context)
        installPlatformNatives(into: context)
        installDownloadsNatives(into: context)
        installBrowserDataNatives(into: context)
        installServiceWorkerFetchNative(into: context)

        // chrome.tabs from the background worker. Hop to the main actor (TabManager is MainActor),
        // run the op, then call back onto this context's queue with the JSON result.
        let tabs: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any = self.host.map {
                    WebExtensionBackgroundContext.dispatchTab(host: $0, method: method, args: args)
                } ?? NSNull()
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(tabs, forKeyedSubscript: "__bb_tabs" as NSString)

        // chrome.scripting (+ MV2 tabs.executeScript/insertCSS) from the background worker. Async on
        // the host (it awaits the page eval), so we await before calling back.
        let scripting: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let extID = self.extensionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any
                if WebExtensionBackgroundContext.registeredContentScriptMethods.contains(method) {
                    // MV3 dynamic content-script registration — a store op (no tab target), routed to
                    // the shared user-script store so the scripts inject like manifest content scripts.
                    result = await WebExtensionBackgroundContext.dispatchRegisteredContentScripts(
                        extensionID: extID, method: method, args: args)
                } else if let host = self.host {
                    result = await WebExtensionBackgroundContext.dispatchScripting(
                        host: host, method: method, args: args, extensionID: extID)
                } else {
                    result = NSNull()
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(scripting, forKeyedSubscript: "__bb_scripting" as NSString)
    }

    // The runtime/tabs MESSAGING natives (installMessagingNatives — __bb_send_message /
    // __bb_message_response / __bb_tabs_send_message) and the chrome.tabs dispatcher (dispatchTab)
    // live in WebExtensionBackgroundContext+Messaging.swift (file-length limit). dispatchScripting
    // (chrome.scripting / MV2 tabs.executeScript) lives in WebExtensionBackgroundContext+Scripting.swift.

    private func installStorageNatives(into context: JSContext) {
        let get: @convention(block) (String, String, JSValue) -> Void = { [weak self] area, keysJSON, callback in
            guard let self else { return }
            let areaEnum = WebExtensionStorage.Area(rawValue: area) ?? .local
            let keys: [String]? = (keysJSON == "null") ? nil
                : ((try? JSONSerialization.jsonObject(with: Data(keysJSON.utf8))) as? [String])
            Task { [weak self] in
                guard let self else { return }
                let result = await self.storage.get(extensionID: self.extensionID, area: areaEnum, keys: keys)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(get, forKeyedSubscript: "__bb_storage_get" as NSString)

        let set: @convention(block) (String, String, JSValue) -> Void = { [weak self] area, itemsJSON, callback in
            guard let self else { return }
            let areaEnum = WebExtensionStorage.Area(rawValue: area) ?? .local
            let items = ((try? JSONSerialization.jsonObject(with: Data(itemsJSON.utf8))) as? [String: String]) ?? [:]
            Task { [weak self] in
                guard let self else { return }
                await self.storage.set(extensionID: self.extensionID, area: areaEnum, items: items)
                self.callBack(callback, with: nil)
            }
        }
        context.setObject(set, forKeyedSubscript: "__bb_storage_set" as NSString)

        let remove: @convention(block) (String, String, JSValue) -> Void = { [weak self] area, keysJSON, callback in
            guard let self else { return }
            let areaEnum = WebExtensionStorage.Area(rawValue: area) ?? .local
            let keys = ((try? JSONSerialization.jsonObject(with: Data(keysJSON.utf8))) as? [String]) ?? []
            Task { [weak self] in
                guard let self else { return }
                await self.storage.remove(extensionID: self.extensionID, area: areaEnum, keys: keys)
                self.callBack(callback, with: nil)
            }
        }
        context.setObject(remove, forKeyedSubscript: "__bb_storage_remove" as NSString)

        let clear: @convention(block) (String, JSValue) -> Void = { [weak self] area, callback in
            guard let self else { return }
            let areaEnum = WebExtensionStorage.Area(rawValue: area) ?? .local
            Task { [weak self] in
                guard let self else { return }
                await self.storage.clear(extensionID: self.extensionID, area: areaEnum)
                self.callBack(callback, with: nil)
            }
        }
        context.setObject(clear, forKeyedSubscript: "__bb_storage_clear" as NSString)
    }

    private func installAlarmNatives(into context: JSContext) {
        let create: @convention(block) (String, Double, Double) -> Void = { [weak self] name, whenMs, periodMinutes in
            self?.createAlarm(name: name, whenMs: whenMs, periodMinutes: periodMinutes)
        }
        context.setObject(create, forKeyedSubscript: "__bb_alarm_create" as NSString)

        let clear: @convention(block) (String, JSValue) -> Void = { [weak self] name, callback in
            guard let self else { return }
            let existed = self.alarmTimers[name] != nil
            self.alarmTimers[name]?.cancel()
            self.alarmTimers.removeValue(forKey: name)
            self.alarms.removeValue(forKey: name)
            self.callBack(callback, with: existed ? "true" : "false")
        }
        context.setObject(clear, forKeyedSubscript: "__bb_alarm_clear" as NSString)

        let clearAll: @convention(block) (JSValue) -> Void = { [weak self] callback in
            guard let self else { return }
            let existed = !self.alarmTimers.isEmpty
            for timer in self.alarmTimers.values { timer.cancel() }
            self.alarmTimers.removeAll()
            self.alarms.removeAll()
            self.callBack(callback, with: existed ? "true" : "false")
        }
        context.setObject(clearAll, forKeyedSubscript: "__bb_alarm_clear_all" as NSString)

        let get: @convention(block) (String, JSValue) -> Void = { [weak self] name, callback in
            guard let self else { return }
            if let alarm = self.alarms[name] {
                self.callBack(callback, with: self.jsonString(self.alarmObject(name: name, alarm: alarm)))
            } else {
                self.callBack(callback, with: "null")
            }
        }
        context.setObject(get, forKeyedSubscript: "__bb_alarm_get" as NSString)

        let getAll: @convention(block) (JSValue) -> Void = { [weak self] callback in
            guard let self else { return }
            let all = self.alarms.map { self.alarmObject(name: $0.key, alarm: $0.value) }
            self.callBack(callback, with: self.jsonString(all))
        }
        context.setObject(getAll, forKeyedSubscript: "__bb_alarm_get_all" as NSString)
    }

    private func installTimerNatives(into context: JSContext) {
        let setTimer: @convention(block) (JSValue, Double, Bool) -> Double = { [weak self] callback, ms, repeats in
            guard let self else { return 0 }
            return Double(self.scheduleTimer(callback: callback, ms: ms, repeats: repeats))
        }
        context.setObject(setTimer, forKeyedSubscript: "__bb_set_timeout" as NSString)

        let clearTimer: @convention(block) (Double) -> Void = { [weak self] id in
            guard let self else { return }
            let key = Int(id)
            self.pendingZeroDelay.remove(key)   // cancel a queued setTimeout(0) before it runs
            self.timers[key]?.cancel()
            self.timers.removeValue(forKey: key)
        }
        context.setObject(clearTimer, forKeyedSubscript: "__bb_clear_timer" as NSString)
    }

    // MARK: - Alarms / timers (on `queue`)

    private func createAlarm(name: String, whenMs: Double, periodMinutes rawPeriodMinutes: Double) {
        // Cancel a same-named alarm first (Chrome replaces it).
        alarmTimers[name]?.cancel()

        // Chrome clamps a periodic alarm to a 1-minute minimum. Clamp ONCE up front so the stored value
        // (what get()/getAll()/onAlarm report) matches the timer that actually fires — they diverged
        // before (raw period stored, but the timer floored at 1s).
        let periodMinutes = rawPeriodMinutes > 0 ? max(1.0, rawPeriodMinutes) : rawPeriodMinutes
        let nowMs = Date().timeIntervalSince1970 * 1000
        let firstDelaySeconds: Double
        if whenMs > 0 {
            firstDelaySeconds = max(0, (whenMs - nowMs) / 1000)
        } else if periodMinutes > 0 {
            firstDelaySeconds = periodMinutes * 60
        } else {
            firstDelaySeconds = 0
        }
        let scheduledTime = nowMs + firstDelaySeconds * 1000
        alarms[name] = AlarmState(scheduledTime: scheduledTime, periodInMinutes: periodMinutes)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        if periodMinutes > 0 {
            // Floor a periodic alarm at 1s so a sub-second periodInMinutes can't spin the queue.
            timer.schedule(deadline: .now() + firstDelaySeconds, repeating: max(1.0, periodMinutes * 60))
        } else {
            timer.schedule(deadline: .now() + firstDelaySeconds)
        }
        timer.setEventHandler { [weak self] in
            guard let self, self.isAlive else { return }
            // Fire onAlarm with the REAL alarm object (name + scheduledTime + periodInMinutes), not a
            // name with a reconstructed Date.now() scheduledTime.
            let alarm = self.alarms[name]
                ?? AlarmState(scheduledTime: Date().timeIntervalSince1970 * 1000, periodInMinutes: periodMinutes)
            self.fire(method: "dispatchAlarm", arguments: [self.jsonString(self.alarmObject(name: name, alarm: alarm))])
            if periodMinutes <= 0 {
                self.alarmTimers[name]?.cancel()
                self.alarmTimers.removeValue(forKey: name)
                self.alarms.removeValue(forKey: name)
            } else {
                // Advance the stored scheduledTime to the next firing so a later get()/onAlarm is accurate.
                self.alarms[name]?.scheduledTime = Date().timeIntervalSince1970 * 1000 + periodMinutes * 60 * 1000
            }
        }
        alarmTimers[name] = timer
        timer.resume()
    }

    private func scheduleTimer(callback: JSValue, ms: Double, repeats: Bool) -> Int {
        timerCounter += 1
        let id = timerCounter
        let seconds = max(0, ms / 1000)
        // Fast path for setTimeout(fn, 0) one-shots. A DispatchSourceTimer per call is heavy, and the
        // IndexedDB engine (fake-indexeddb) drains a transaction by rescheduling its run loop through MANY
        // setTimeout(0) macrotasks — on iOS the per-timer create/resume/cancel overhead made IDB-heavy
        // inits crawl: Tampermonkey's userscript-tree load didn't finish before its popup asked, so the
        // popup blanked with "unable to load tree" (the alarm/storage paths, which don't lean on IDB,
        // worked fine — confirmed via the [bb-bg] device diagnostic). queue.async runs the callback in the
        // next serial-queue turn — the same one-task-per-turn macrotask semantics fake-indexeddb relies on,
        // FIFO-ordered — at a fraction of the cost. clearTimeout still cancels it via pendingZeroDelay.
        if !repeats && seconds == 0 {
            pendingZeroDelay.insert(id)
            queue.async { [weak self] in
                guard let self, self.isAlive else { return }
                guard self.pendingZeroDelay.remove(id) != nil else { return }   // cancelled by clearTimeout
                callback.call(withArguments: [])
            }
            return id
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        if repeats {
            // Floor at 4ms (the HTML spec's nested-timer clamp) so setInterval(fn, 0) can't spin the
            // serial queue at ~1000 Hz and starve everything else on it.
            timer.schedule(deadline: .now() + seconds, repeating: max(0.004, seconds))
        } else {
            timer.schedule(deadline: .now() + seconds)
        }
        timer.setEventHandler { [weak self] in
            guard let self, self.isAlive else { return }
            callback.call(withArguments: [])
            if !repeats {
                self.timers[id]?.cancel()
                self.timers.removeValue(forKey: id)
            }
        }
        timers[id] = timer
        timer.resume()
        return id
    }

    private func alarmObject(name: String, alarm: AlarmState) -> [String: Any] {
        var object: [String: Any] = ["name": name, "scheduledTime": alarm.scheduledTime]
        if alarm.periodInMinutes > 0 { object["periodInMinutes"] = alarm.periodInMinutes }
        return object
    }

    // MARK: - Helpers (on `queue`)

    // Internal (not private) so +Platform's fireIdleStateChanged can dispatch onto the JSContext. Both
    // MUST be used on `queue`.
    func fire(method: String, arguments: [Any]) {
        guard isAlive, let context,
              let dispatcher = context.objectForKeyedSubscript("__bbBg"), !dispatcher.isUndefined else { return }
        dispatcher.invokeMethod(method, withArguments: arguments)
    }

    // Internal (not private) so the messaging natives in WebExtensionBackgroundContext+Messaging.swift
    // can resolve a parked continuation when the worker answers a content/popup message.
    func resolveResponse(_ responseId: String, payload: [String: Any]?) {
        guard let continuation = pendingResponses.removeValue(forKey: responseId) else { return }
        // Diagnostic: report WHAT the worker answered. A ScriptCat GM_xmlhttpRequest 200 whose reply comes
        // back to the content side null/empty (so the userscript's onload never fires and it refetches) is
        // otherwise invisible — the "deferred — awaiting reply" line only proves the request was dispatched.
        if let label = pendingResponseLabels.removeValue(forKey: responseId), !label.isEmpty {
            let value = payload?["value"]
            let size: Int
            if let value, !(value is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: ["v": value]) {
                size = data.count - 8   // minus the {"v":} wrapper
            } else {
                size = 0
            }
            logSink(makeLog(.debug, "[bb-bg] reply\(label): \(size > 0 ? "value \(size)b" : "EMPTY/null") "
                + "(worker sendResponse → content)"))
        }
        continuation.resume(returning: payload)
    }

    /// Invoke a stored JS callback on `queue` with an optional single JSON-string argument.
    // `internal` (not `private`) so the same-module +Fetch extension file can hop a native result back
    // onto this context's queue; the splitting is only to keep this file under the length limit.
    func callBack(_ callback: JSValue, with argument: String?) {
        queue.async { [weak self] in
            guard let self, self.isAlive else { return }
            if let argument {
                callback.call(withArguments: [argument])
            } else {
                callback.call(withArguments: [])
            }
        }
    }

    func jsonString(_ value: Any) -> String {
        // Sanitize NaN/Infinity first — JSONSerialization throws an uncatchable Obj-C exception on
        // those, and a content script's message / tab record can carry one (CLAUDE.md §5: fail closed).
        JSONSanitize.string(value)
    }

    func makeLog(_ level: LogEntry.Level, _ message: String) -> LogEntry {
        LogEntry(scriptID: nil, scriptName: extensionName, level: level,
                 message: message, context: .background, source: .engine)
    }
}

// MARK: - chrome.cookies + chrome.notifications natives
//
// Split into a same-file extension so the primary type body stays under the length limit; a same-file
// extension still reaches the class's `private` members (queue/callBack/jsonString/fire/host/…).
extension WebExtensionBackgroundContext {

    /// chrome.cookies from the background worker. Hop to the main actor (WKHTTPCookieStore lives on
    /// the browser's data stores, reached via the cookie host), run the op, then call back onto this
    /// context's serial queue with the JSON result. The worker is privileged but still gated: we
    /// check the `cookies` permission + a host_permission for the target here before the call.
    private func installCookiesNatives(into context: JSContext) {
        let cookies: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any
                if let host = self.cookieHost, self.cookiePermitted(method: method, args: args) {
                    result = await WebExtensionBackgroundContext.dispatchCookies(host: host, method: method, args: args)
                } else {
                    result = NSNull()
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(cookies, forKeyedSubscript: "__bb_cookies" as NSString)
    }

    /// Whether this extension's manifest grants the `cookies` permission AND (for reads/writes) a
    /// host_permission covering the target. getAllCookieStores needs only the cookies permission.
    private func cookiePermitted(method: String, args: [String: Any]) -> Bool {
        guard cookiePermissions.contains("cookies") else { return false }
        if method == "getAllCookieStores" { return true }
        let details = (args["details"] as? [String: Any]) ?? [:]
        // Gate on the cookie's EFFECTIVE domain (an explicit `domain` wins over `url`) — the same
        // gate the foreground router uses, closing the cross-domain cookies.set bypass here too.
        return WebExtensionCookieMapper.scopeAllowed(details: details, hostMatches: cookieHostMatcher)
    }

    /// Map a chrome.cookies method + args to the cookie host, returning a JSON-serializable value.
    @MainActor
    private static func dispatchCookies(host: WebExtensionCookieBridgeHost, method: String, args: [String: Any]) async -> Any {
        let details = (args["details"] as? [String: Any]) ?? [:]
        let storeId = details["storeId"] as? String
        switch method {
        case "get":
            guard let url = details["url"] as? String, let name = details["name"] as? String else { return NSNull() }
            return await host.webExtGetCookie(url: url, name: name, storeId: storeId) ?? NSNull()
        case "getAll":
            return await host.webExtGetAllCookies(filter: details, storeId: storeId)
        case "set":
            return await host.webExtSetCookie(details: details, storeId: storeId) ?? NSNull()
        case "remove":
            guard let url = details["url"] as? String, let name = details["name"] as? String else { return NSNull() }
            return await host.webExtRemoveCookie(url: url, name: name, storeId: storeId) ?? NSNull()
        case "getAllCookieStores":
            return host.webExtGetAllCookieStores()
        default:
            return NSNull()
        }
    }

    /// Fire chrome.cookies.onChanged for a single change record (called from the main actor by the
    /// runtime, which observes the global cookie-change notification). Hops onto `queue` before the
    /// JSContext is touched, exactly like dispatchStorageChanged.
    func dispatchCookieChanged(change: [String: Any]) {
        let changeJSON = jsonString(change)
        queue.async { [self] in
            fire(method: "dispatchCookieChanged", arguments: [changeJSON])
        }
    }

    /// chrome.notifications from the background worker. UNUserNotificationCenter is async and confined
    /// to the main actor (via WebExtensionNotificationManager), so hop to the main actor, run the op,
    /// then call back onto this context's queue with the JSON result. Mirrors __bb_tabs / dispatchTab.
    private func installNotificationNatives(into context: JSContext) {
        let notifications: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let extensionID = self.extensionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any
                if let host = self.host {
                    result = await WebExtensionBackgroundContext.dispatchNotification(
                        host: host, method: method, args: args, extensionID: extensionID)
                } else {
                    result = NSNull()
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(notifications, forKeyedSubscript: "__bb_notifications" as NSString)
    }

    /// Map a chrome.notifications method + args to the bridge host, returning a JSON-serializable value.
    /// On a permission/disabled error we resolve NSNull rather than reject the worker (it would crash
    /// an otherwise-harmless worker that touches notifications without the permission).
    @MainActor
    private static func dispatchNotification(host: WebExtensionBridgeHost, method: String,
                                             args: [String: Any], extensionID: String) async -> Any {
        do {
            switch method {
            case "create":
                return try await host.webExtNotificationsCreate(
                    extensionID: extensionID,
                    notificationID: args["notificationId"] as? String,
                    options: args["options"] as? [String: Any] ?? [:])
            case "update":
                guard let id = args["notificationId"] as? String else { return false }
                return try await host.webExtNotificationsUpdate(
                    extensionID: extensionID, notificationID: id,
                    options: args["options"] as? [String: Any] ?? [:])
            case "clear":
                guard let id = args["notificationId"] as? String else { return false }
                return try await host.webExtNotificationsClear(extensionID: extensionID, notificationID: id)
            case "getAll":
                return try await host.webExtNotificationsGetAll(extensionID: extensionID)
            default:
                return NSNull()
            }
        } catch {
            // Return an error marker (was a silent NSNull phantom-success); the JS notifications shim
            // unwraps {__bbError} to reject + log, so a failing chrome.notifications call is diagnosable.
            return ["__bbError": error.localizedDescription]
        }
    }

    /// Fan a chrome.notifications event (clicked/closed/buttonClicked) into this worker's listeners.
    /// Called from WebExtensionRuntime on the main actor; hops onto this context's serial queue before
    /// touching the JSContext, mirroring dispatchStorageChanged.
    func dispatchNotificationEvent(kind: String, notificationID: String, byUser: Bool, buttonIndex: Int) {
        let idJSON = jsonString(notificationID)
        queue.async { [self] in
            switch kind {
            case "clicked":
                fire(method: "dispatchNotificationClicked", arguments: [idJSON])
            case "closed":
                fire(method: "dispatchNotificationClosed", arguments: [idJSON, byUser])
            case "buttonClicked":
                fire(method: "dispatchNotificationButtonClicked", arguments: [idJSON, buttonIndex])
            default:
                break
            }
        }
    }

    /// chrome.action / chrome.browserAction from the background worker. State writes/reads hop to the
    /// main actor (WebExtensionActionState is @MainActor), then call back on this context's queue with
    /// the JSON result. chrome.action needs no permission (Chrome gates it on the manifest action entry).
    private func installActionNatives(into context: JSContext) {
        let action: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            let extensionID = self.extensionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = WebExtensionBackgroundContext.dispatchAction(
                    state: BrownBearServices.shared.webExtensionActionState,
                    extensionID: extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(action, forKeyedSubscript: "__bb_action" as NSString)
    }

    /// Map a chrome.action method + args to WebExtensionActionState, returning a JSON-serializable
    /// value (NSNull for the void setters, the read value for the getters).
    @MainActor
    private static func dispatchAction(state: WebExtensionActionState, extensionID: String,
                                       method: String, args: [String: Any]) -> Any {
        let tabId = args["tabId"] as? Int
        switch method {
        case "setBadgeText":
            state.setBadgeText(extensionID: extensionID, tabId: tabId, text: args["text"] as? String)
            return NSNull()
        case "setBadgeBackgroundColor":
            state.setBadgeColor(extensionID: extensionID, tabId: tabId, color: args["color"] as? String)
            return NSNull()
        case "setBadgeTextColor":
            state.setBadgeTextColor(extensionID: extensionID, tabId: tabId, color: args["color"] as? String)
            return NSNull()
        case "setTitle":
            state.setTitle(extensionID: extensionID, tabId: tabId, title: args["title"] as? String)
            return NSNull()
        case "setPopup":
            state.setPopup(extensionID: extensionID, tabId: tabId, popup: args["popup"] as? String)
            return NSNull()
        case "setIcon":
            state.setIcon(extensionID: extensionID, tabId: tabId,
                          path: WebExtensionActionState.iconPath(from: args["path"]))
            return NSNull()
        case "enable":
            state.setEnabled(extensionID: extensionID, tabId: tabId, true)
            return NSNull()
        case "disable":
            state.setEnabled(extensionID: extensionID, tabId: tabId, false)
            return NSNull()
        case "getBadgeText":
            return state.badgeText(extensionID: extensionID, tabId: tabId)
        case "getTitle":
            return state.title(extensionID: extensionID, tabId: tabId)
        case "getBadgeBackgroundColor":
            return state.badgeColorBytes(extensionID: extensionID, tabId: tabId)
        case "getBadgeTextColor":
            return state.badgeTextColorBytes(extensionID: extensionID, tabId: tabId)
        case "openPopup":
            // Present the extension's popup over the browser — the same toolbar-anchored glassy popover a
            // user tap opens. Routed to the live browser via the bridge host; a no-op if it has no popup.
            BrownBearServices.shared.webExtensionRuntime.host?.webExtTriggerAction(extensionID: extensionID)
            return NSNull()
        default:
            return NSNull()
        }
    }

    /// Fire chrome.action.onClicked into this worker with a Tab record (or null if no active tab).
    /// Called from the main actor (the browser's action trigger); hops to `queue` to touch the JS.
    func fireActionClicked(tab: [String: Any]?) {
        let tabJSON = jsonString(tab ?? NSNull())
        queue.async { [self] in
            fire(method: "dispatchActionClicked", arguments: [tabJSON])
        }
    }

    /// chrome.contextMenus from the background worker. create/update/remove/removeAll hop to the main
    /// actor (the store is @MainActor), run the op, then call back onto this context's serial queue with
    /// the JSON result ({id} | null | {error}). Mirrors __bb_dnr / __bb_userscripts.
    private func installContextMenuNatives(into context: JSContext) {
        let extensionID = self.extensionID
        let contextMenus: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await WebExtensionBackgroundContext.dispatchContextMenus(
                    extensionID: extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(contextMenus, forKeyedSubscript: "__bb_context_menus" as NSString)
    }

    /// Fire chrome.contextMenus.onClicked into this worker with the OnClickData info object + the Tab
    /// record (or null). Called from the main actor (the browser's long-press tap); hops to `queue` to
    /// touch the JSContext, exactly like fireActionClicked.
    func fireContextMenuClicked(info: [String: Any], tab: [String: Any]?) {
        let infoJSON = jsonString(info)
        let tabJSON = jsonString(tab ?? NSNull())
        queue.async { [self] in
            fire(method: "dispatchContextMenuClicked", arguments: [infoJSON, tabJSON])
        }
    }

    /// chrome.declarativeNetRequest + chrome.userScripts for the BACKGROUND worker. Pure store ops; each
    /// native hops to the main actor to reach BrownBearServices.shared, drives the async actor call, then
    /// callBacks onto this context's queue with the JSON result. Mirrors the __bb_tabs pattern.
    private func installDNRAndUserScriptNatives(into context: JSContext) {
        let extensionID = self.extensionID
        let dnr: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await WebExtensionBackgroundContext.dispatchDNR(extensionID: extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(dnr, forKeyedSubscript: "__bb_dnr" as NSString)

        let userScripts: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any
                if method == "execute", let host = self.host {
                    // execute targets a TAB (needs host + host access), unlike the store-only register/world
                    // methods — route it through the host the same way chrome.scripting.executeScript is.
                    result = await WebExtensionBackgroundContext.dispatchUserScriptExecute(
                        host: host, args: args, extensionID: extensionID)
                } else {
                    result = await WebExtensionBackgroundContext.dispatchUserScripts(
                        extensionID: extensionID, method: method, args: args)
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(userScripts, forKeyedSubscript: "__bb_userscripts" as NSString)
    }

    // MARK: - Port helpers (internal, for the +Ports file which can't reach private queue/fire/jsonString)
    func firePortDispatch(method: String, arguments: [Any]) {
        queue.async { [self] in fire(method: method, arguments: arguments) }
    }
    func encodePortJSON(_ value: Any) -> String { jsonString(value) }
}
