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
    /// Granted API permissions, cached by the runtime at boot. Defense-in-depth for event gating (the
    /// authoritative webNavigation gate lives in WebExtensionRuntime.dispatchEventToAll). On `queue`.
    private var grantedPermissions: Set<String> = []

    private let queue: DispatchQueue
    private var context: JSContext?
    private var isAlive = true

    // Pending content→background message replies, keyed by a per-context response id.
    private var pendingResponses: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var responseCounter = 0

    // chrome.alarms — in-memory, foreground-lifetime GCD timers.
    private struct AlarmState { var scheduledTime: Double; var periodInMinutes: Double }
    private var alarms: [String: AlarmState] = [:]
    private var alarmTimers: [String: DispatchSourceTimer] = [:]

    // setTimeout / setInterval registry.
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var timerCounter = 0

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
                self.logSink(self.makeLog(.error, "uncaught: \(value?.toString() ?? "unknown exception")"))
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
            }

            // Configuration globals the runtime reads on load.
            context.setObject(manifestJSON, forKeyedSubscript: "__bbBgManifest" as NSString)
            context.setObject(extensionID, forKeyedSubscript: "__bbBgExtId" as NSString)
            context.setObject(baseURL, forKeyedSubscript: "__bbBgBaseURL" as NSString)
            let messagesJSON = jsonString(messages)
            context.setObject(messagesJSON, forKeyedSubscript: "__bbBgMessages" as NSString)
            // Device-derived inputs for the navigator polyfill (JSC has no DOM; see HeadlessEnvironment).
            context.setObject(HeadlessEnvironment.userAgent, forKeyedSubscript: "__bbUserAgent" as NSString)
            context.setObject(HeadlessEnvironment.language, forKeyedSubscript: "__bbLanguage" as NSString)
            // IndexedDB engine + rehydrate this extension's snapshot before its background source runs.
            BrownBearIDBStore.shared.install(into: context, namespace: .ext(extensionID))
            context.evaluateScript(runtimeJS, withSourceURL: URL(string: "brownbear://webext/\(extensionID)/runtime.js"))
            if let moduleEntry, let esmRuntimeJS, let moduleSource {
                // MV3 module service worker: link the module graph in-context (no native ESM loader).
                runModuleWorker(in: context, esmRuntimeJS: esmRuntimeJS,
                                entryPath: moduleEntry, moduleSource: moduleSource)
            } else {
                // Wrap in a function so a worker/background script using a top-level `return` (some
                // ScriptCat-derived bundles do) is valid — a bare top-level `return` is a SyntaxError.
                // Body starts on line 1 of the wrapper so error line numbers still line up.
                let wrappedSource = "(function(){" + backgroundSource + "\n})();"
                context.evaluateScript(wrappedSource, withSourceURL: URL(string: "brownbear://webext/\(extensionID)/background.js"))
            }

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
            alarms.removeAll()
            // Resolve anything still waiting so callers never hang.
            for (_, continuation) in pendingResponses { continuation.resume(returning: nil) }
            pendingResponses.removeAll()
            context = nil
        }
    }

    // MARK: - Inbound events (called from the main actor)

    /// Deliver a content-script message to this extension's runtime.onMessage listeners and await
    /// the (possibly async) sendResponse. Resolves to `["value": ...]`, or nil if nothing answered.
    func deliverRuntimeMessage(message: Any, sender: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            queue.async { [self] in
                guard isAlive, let context else { continuation.resume(returning: nil); return }
                responseCounter += 1
                let responseId = "r\(responseCounter)"
                pendingResponses[responseId] = continuation

                let messageJSON = jsonString(message)
                let senderJSON = jsonString(sender)
                if let dispatcher = context.objectForKeyedSubscript("__bbBg"),
                   !dispatcher.isUndefined {
                    dispatcher.invokeMethod("dispatchMessage", withArguments: [messageJSON, senderJSON, responseId])
                } else {
                    resolveResponse(responseId, payload: nil)
                    return
                }

                // Don't leak a continuation if a listener returns `true` then never responds.
                queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.resolveResponse(responseId, payload: nil)
                }
            }
        }
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

        installStorageNatives(into: context)
        installAlarmNatives(into: context)
        installTimerNatives(into: context)
        installMessagingNatives(into: context)
        installCookiesNatives(into: context)
        installNotificationNatives(into: context)
        installActionNatives(into: context)
        installWindowsManagementPermissionsNatives(into: context)
        installDNRAndUserScriptNatives(into: context)
        installCryptoNatives(into: context)
        installFetchNative(into: context)
        installContextMenuNatives(into: context)
        installPortNatives(into: context)

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

    /// The runtime/tabs MESSAGING natives: the worker sending a runtime message, answering a content
    /// script's pushed message (resolving a parked continuation), and chrome.tabs.sendMessage out to a
    /// tab's content scripts. Grouped so installNatives stays readable as the surface grows.
    private func installMessagingNatives(into context: JSContext) {
        // background runtime.sendMessage → other extension contexts. Content scripts receive via
        // tabs.sendMessage, not this. Delivery from a CONTENT SCRIPT or PAGE to an open popup/options
        // page is wired through WebExtensionRuntime.sendRuntimeMessage; the worker-as-SENDER path
        // (background → page) is not yet routed here, so resolve with no value for now.
        let sendMessage: @convention(block) (String, JSValue) -> Void = { [weak self] _, callback in
            self?.callBack(callback, with: "null")
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

    // dispatchScripting (chrome.scripting / MV2 tabs.executeScript, permission+host gated) lives in
    // WebExtensionBackgroundContext+Scripting.swift (file-length limit).

    /// Map a chrome.tabs method + args to the bridge host, returning a JSON-serializable value.
    @MainActor
    private static func dispatchTab(host: WebExtensionBridgeHost, method: String, args: [String: Any]) -> Any {
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
            self.timers[key]?.cancel()
            self.timers.removeValue(forKey: key)
        }
        context.setObject(clearTimer, forKeyedSubscript: "__bb_clear_timer" as NSString)
    }

    // MARK: - Alarms / timers (on `queue`)

    private func createAlarm(name: String, whenMs: Double, periodMinutes: Double) {
        // Cancel a same-named alarm first (Chrome replaces it).
        alarmTimers[name]?.cancel()

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
            self.fire(method: "dispatchAlarm", arguments: [self.jsonString(name)])
            if periodMinutes <= 0 {
                self.alarmTimers[name]?.cancel()
                self.alarmTimers.removeValue(forKey: name)
                self.alarms.removeValue(forKey: name)
            }
        }
        alarmTimers[name] = timer
        timer.resume()
    }

    private func scheduleTimer(callback: JSValue, ms: Double, repeats: Bool) -> Int {
        timerCounter += 1
        let id = timerCounter
        let seconds = max(0, ms / 1000)
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

    private func fire(method: String, arguments: [Any]) {
        guard isAlive, let context,
              let dispatcher = context.objectForKeyedSubscript("__bbBg"), !dispatcher.isUndefined else { return }
        dispatcher.invokeMethod(method, withArguments: arguments)
    }

    private func resolveResponse(_ responseId: String, payload: [String: Any]?) {
        guard let continuation = pendingResponses.removeValue(forKey: responseId) else { return }
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
            return NSNull()
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

    /// chrome.windows / chrome.management / chrome.permissions + the real runtime.openOptionsPage and
    /// runtime.setUninstallURL for the BACKGROUND worker. windows hop to the browser host on the main
    /// actor; management/permissions read the store + grants actors (off BrownBearServices.shared,
    /// which is @MainActor) then call back on this context's serial queue.
    private func installWindowsManagementPermissionsNatives(into context: JSContext) {
        let windows: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any = self.host.map {
                    WebExtensionBackgroundContext.dispatchWindow(host: $0, method: method, args: args)
                } ?? NSNull()
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(windows, forKeyedSubscript: "__bb_windows" as NSString)

        let management: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let store = BrownBearServices.shared.webExtensionStore
                let result = await WebExtensionBackgroundContext.dispatchManagement(
                    store: store, selfID: self.extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(management, forKeyedSubscript: "__bb_management" as NSString)

        let permissions: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let store = BrownBearServices.shared.webExtensionStore
                let grants = BrownBearServices.shared.webExtensionPermissionGrants
                let result = await WebExtensionBackgroundContext.dispatchPermissions(
                    store: store, grants: grants, extensionID: self.extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(permissions, forKeyedSubscript: "__bb_permissions" as NSString)

        let openOptions: @convention(block) (JSValue) -> Void = { [weak self] callback in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ok = self.host?.webExtOpenOptionsPage(extensionID: self.extensionID) ?? false
                self.callBack(callback, with: ok ? "true" : "false")
            }
        }
        context.setObject(openOptions, forKeyedSubscript: "__bb_runtime_open_options" as NSString)

        let setUninstallURL: @convention(block) (String, JSValue) -> Void = { [weak self] url, callback in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let grants = BrownBearServices.shared.webExtensionPermissionGrants
                await grants.setUninstallURL(extensionID: self.extensionID, url: url)
                self.callBack(callback, with: nil)
            }
        }
        context.setObject(setUninstallURL, forKeyedSubscript: "__bb_runtime_set_uninstall_url" as NSString)
    }

    /// Map a chrome.windows method + args to the bridge host, returning a JSON-serializable value.
    @MainActor
    private static func dispatchWindow(host: WebExtensionBridgeHost, method: String, args: [String: Any]) -> Any {
        let populate = (args["populate"] as? Bool) ?? false
        switch method {
        case "get", "getCurrent", "getLastFocused":
            return host.webExtWindow(populate: populate)
        case "getAll":
            return host.webExtAllWindows(populate: populate)
        case "create":
            return host.webExtCreateWindow(url: args["url"] as? String,
                                           active: (args["focused"] as? Bool) ?? true,
                                           populate: populate)
        case "update":
            return host.webExtUpdateWindow(populate: populate)
        default:
            return NSNull()   // remove et al. — no-op on a single, unclosable window
        }
    }

    /// chrome.management reads, off the WebExtensionStore actor.
    private static func dispatchManagement(store: WebExtensionStore, selfID: String,
                                           method: String, args: [String: Any]) async -> Any {
        switch method {
        case "getAll":
            return WebExtensionManagementInfo.allExtensionInfos(await store.all())
        case "get":
            guard let id = args["id"] as? String, let ext = await store.ext(for: id) else { return NSNull() }
            return WebExtensionManagementInfo.extensionInfo(for: ext)
        case "getSelf":
            guard let ext = await store.ext(for: selfID) else { return NSNull() }
            return WebExtensionManagementInfo.extensionInfo(for: ext)
        default:
            return NSNull()
        }
    }

    /// chrome.permissions reconciliation, off the store + grant actors. `request` now shows a user
    /// consent prompt (WebExtensionPermissionPrompt) before granting any NEW optional permission,
    /// replacing the previous silent auto-grant. Runs on the main actor (called from a @MainActor Task),
    /// so presenting the prompt and reading the store/grants is race-free here.
    @MainActor
    private static func dispatchPermissions(store: WebExtensionStore,
                                            grants: WebExtensionPermissionGrants,
                                            extensionID: String, method: String,
                                            args: [String: Any]) async -> Any {
        let ext = await store.ext(for: extensionID)
        let manifest = ext?.manifest
        let requested = WebExtensionManagementInfo.PermissionSet(payload: args)
        let granted = await grants.granted(extensionID: extensionID)
        switch method {
        case "getAll":
            return WebExtensionManagementInfo.effective(manifest: manifest, granted: granted).dictionary
        case "contains":
            return WebExtensionManagementInfo.contains(requested, manifest: manifest, granted: granted)
        case "request":
            guard let toGrant = WebExtensionManagementInfo.resolveRequest(requested, manifest: manifest) else {
                return false
            }
            // Prompt only for what isn't already held; an already-held request resolves true silently.
            let effective = WebExtensionManagementInfo.effective(manifest: manifest, granted: granted)
            var newlyRequested = toGrant
            newlyRequested.permissions.subtract(effective.permissions)
            newlyRequested.origins.subtract(effective.origins)
            guard await WebExtensionPermissionPrompt.request(extensionName: ext?.displayName ?? extensionID,
                                                             toGrant: newlyRequested) else { return false }
            await grants.grant(extensionID: extensionID, newlyRequested)
            return true
        case "remove":
            guard let remaining = WebExtensionManagementInfo.resolveRemove(requested, manifest: manifest, granted: granted) else {
                return false
            }
            await grants.setGranted(extensionID: extensionID, remaining)
            return true
        default:
            return NSNull()
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
                let result = await WebExtensionBackgroundContext.dispatchUserScripts(extensionID: extensionID, method: method, args: args)
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
