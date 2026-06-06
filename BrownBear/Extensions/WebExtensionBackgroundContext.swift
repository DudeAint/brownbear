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

import Foundation
import JavaScriptCore

final class WebExtensionBackgroundContext: @unchecked Sendable {

    let extensionID: String
    private let extensionName: String
    private let storage: WebExtensionStorage
    private let logSink: @Sendable (LogEntry) -> Void

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
    func boot(runtimeJS: String, backgroundSource: String,
              manifestJSON: String, baseURL: String, messages: [String: String],
              firstInstall: Bool = true) {
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

            // Configuration globals the runtime reads on load.
            context.setObject(manifestJSON, forKeyedSubscript: "__bbBgManifest" as NSString)
            context.setObject(extensionID, forKeyedSubscript: "__bbBgExtId" as NSString)
            context.setObject(baseURL, forKeyedSubscript: "__bbBgBaseURL" as NSString)
            let messagesJSON = jsonString(messages)
            context.setObject(messagesJSON, forKeyedSubscript: "__bbBgMessages" as NSString)

            context.evaluateScript(runtimeJS, withSourceURL: URL(string: "brownbear://webext/\(extensionID)/runtime.js"))
            context.evaluateScript(backgroundSource, withSourceURL: URL(string: "brownbear://webext/\(extensionID)/background.js"))

            // onInstalled fires ONLY on the first-ever boot of this extension (Chrome contract);
            // onStartup fires on every boot. Firing 'install' on each launch/reload would re-run
            // first-run setup (opening tabs, seeding storage) every time.
            if firstInstall { fire(method: "fireInstalled", arguments: ["install"]) }
            fire(method: "fireStartup", arguments: [])
        }
    }

    func shutdown() {
        queue.async { [self] in
            isAlive = false
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

        // background → others. We can't address content scripts/popups yet (Phase 3), so resolve
        // with no receiver rather than hang the caller.
        let sendMessage: @convention(block) (String, JSValue) -> Void = { [weak self] _, callback in
            self?.callBack(callback, with: "null")
        }
        context.setObject(sendMessage, forKeyedSubscript: "__bb_send_message" as NSString)

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
    private func callBack(_ callback: JSValue, with argument: String?) {
        queue.async { [weak self] in
            guard let self, self.isAlive else { return }
            if let argument {
                callback.call(withArguments: [argument])
            } else {
                callback.call(withArguments: [])
            }
        }
    }

    private func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }

    private func makeLog(_ level: LogEntry.Level, _ message: String) -> LogEntry {
        LogEntry(scriptID: nil, scriptName: extensionName, level: level,
                 message: message, context: .background)
    }
}
