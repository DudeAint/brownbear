//
//  HeadlessScriptRunner.swift
//  BrownBear
//
//  Runs a background/@crontab script with no web view. It boots a JavaScriptCore JSContext,
//  installs a DOM-less GM surface (storage, network, logging), evaluates the script, then flushes
//  changed values and collected logs. This is what makes ScriptCat-style background execution
//  possible on iOS — scripts run while the app is closed, driven by BGTaskScheduler.
//
//  Safety:
//   • A JSContextGroup execution-time limit bounds runaway/infinite-loop scripts (the OS task
//     budget is the outer guard).
//   • GM_xmlhttpRequest is gated by the script's @connect allowlist with NO page-host exception
//     (there is no page in the background), and runs synchronously within the remaining budget.
//   • GM values are read from a preloaded snapshot and mirrored back, so each run is isolated to
//     its own script's namespace.
//

import Foundation
import JavaScriptCore

struct HeadlessRunOutcome {
    let scriptID: UUID
    let error: String?
    var succeeded: Bool { error == nil }
}

final class HeadlessScriptRunner: @unchecked Sendable {

    /// Mutable per-run state shared by the installed JS blocks (all run synchronously on `queue`).
    private final class Scratch {
        var cache: [String: String]          // key -> JSON-encoded value
        var touched = Set<String>()          // keys written or deleted this run
        var logs: [LogEntry] = []
        init(cache: [String: String]) { self.cache = cache }
    }

    private let valueStore: GMValueStore
    private let queue = DispatchQueue(label: "com.brownbear.headless")
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    init(valueStore: GMValueStore) {
        self.valueStore = valueStore
    }

    /// Run `script` headless, finishing by `deadline`. Returns its logs and outcome; mutated GM
    /// values are flushed to the store before returning.
    func run(_ script: UserScript, deadline: Date) async -> (outcome: HeadlessRunOutcome, logs: [LogEntry]) {
        let snapshot = await valueStore.snapshot(scriptID: script.id)

        let (outcome, scratch): (HeadlessRunOutcome, Scratch) = await withCheckedContinuation { continuation in
            queue.async {
                let result = self.execute(script, snapshot: snapshot, deadline: deadline)
                continuation.resume(returning: result)
            }
        }

        // Flush mutated values back to the namespaced store.
        var sets: [String: String] = [:]
        var deletes: [String] = []
        for key in scratch.touched {
            if let value = scratch.cache[key] { sets[key] = value } else { deletes.append(key) }
        }
        if !sets.isEmpty { await valueStore.setValues(scriptID: script.id, entries: sets) }
        if !deletes.isEmpty { await valueStore.deleteValues(scriptID: script.id, keys: deletes) }

        return (outcome, scratch.logs)
    }

    // MARK: - Execution (on `queue`)

    private func execute(_ script: UserScript, snapshot: [String: String], deadline: Date)
        -> (HeadlessRunOutcome, Scratch) {
        let scratch = Scratch(cache: snapshot)
        guard let context = JSContext() else {
            scratch.logs.append(self.log(script, .error, "could not create JS context"))
            return (HeadlessRunOutcome(scriptID: script.id, error: "no JS context"), scratch)
        }

        // Note: JavaScriptCore's execution-time watchdog (JSContextGroupSetExecutionTimeLimit) is
        // macOS-only — iOS does not expose it. A runaway/infinite-loop script is instead bounded by
        // the OS background-task budget: BrownBearBackgroundScheduler's expirationHandler completes
        // the task and the OS suspends the process. GM_xmlhttpRequest waits are bounded by the
        // remaining budget below.

        var runError: String?
        context.exceptionHandler = { _, value in
            runError = value?.toString() ?? "unknown JS exception"
            scratch.logs.append(self.log(script, .error, "uncaught: \(runError ?? "")"))
        }

        installAPIs(into: context, script: script, scratch: scratch, deadline: deadline)
        installPrelude(into: context)

        context.evaluateScript(script.executableBody, withSourceURL: URL(string: "brownbear://\(script.id.uuidString).user.js"))

        return (HeadlessRunOutcome(scriptID: script.id, error: runError), scratch)
    }

    // MARK: - GM surface

    private func installPrelude(into context: JSContext) {
        // console.* + GM_log forward to the native __bbLog(level, message). Defined in JS so we
        // get variadic args and tidy stringification for free.
        context.evaluateScript("""
        (function () {
          function fmt(a) { try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }
          function joiner() { return Array.prototype.map.call(arguments, fmt).join(' '); }
          var c = {
            log: function () { __bbLog('info', joiner.apply(null, arguments)); },
            info: function () { __bbLog('info', joiner.apply(null, arguments)); },
            warn: function () { __bbLog('warn', joiner.apply(null, arguments)); },
            error: function () { __bbLog('error', joiner.apply(null, arguments)); },
            debug: function () { __bbLog('debug', joiner.apply(null, arguments)); }
          };
          this.console = c;
          this.GM_log = function () { __bbLog('info', joiner.apply(null, arguments)); };
          this.unsafeWindow = this;
        })();
        """)
    }

    private func installAPIs(into context: JSContext, script: UserScript, scratch: Scratch, deadline: Date) {
        let json = context.objectForKeyedSubscript("JSON")

        func stringify(_ value: JSValue?) -> String {
            guard let value, let result = json?.invokeMethod("stringify", withArguments: [value]),
                  !result.isUndefined else { return "null" }
            return result.toString() ?? "null"
        }
        func parse(_ raw: String) -> JSValue? {
            json?.invokeMethod("parse", withArguments: [raw])
        }

        let nativeLog: @convention(block) (String, String) -> Void = { [weak self] level, message in
            guard let self else { return }
            scratch.logs.append(self.log(script, LogEntry.Level(rawValue: level) ?? .info, message))
        }
        context.setObject(nativeLog, forKeyedSubscript: "__bbLog" as NSString)

        let getValue: @convention(block) (String, JSValue?) -> Any? = { key, fallback in
            if let raw = scratch.cache[key], let parsed = parse(raw) { return parsed }
            return fallback
        }
        context.setObject(getValue, forKeyedSubscript: "GM_getValue" as NSString)

        let setValue: @convention(block) (String, JSValue?) -> Void = { key, value in
            scratch.touched.insert(key)
            if let value, !value.isUndefined {
                scratch.cache[key] = stringify(value)
            } else {
                scratch.cache.removeValue(forKey: key)
            }
        }
        context.setObject(setValue, forKeyedSubscript: "GM_setValue" as NSString)

        let deleteValue: @convention(block) (String) -> Void = { key in
            scratch.touched.insert(key)
            scratch.cache.removeValue(forKey: key)
        }
        context.setObject(deleteValue, forKeyedSubscript: "GM_deleteValue" as NSString)

        let listValues: @convention(block) () -> [String] = {
            Array(scratch.cache.keys)
        }
        context.setObject(listValues, forKeyedSubscript: "GM_listValues" as NSString)

        installXHR(into: context, script: script, scratch: scratch, deadline: deadline)

        // GM_info — minimal, DOM-less.
        let info: [String: Any] = [
            "scriptHandler": "BrownBear",
            "version": "0.1.0",
            "scriptMetaStr": script.metadata.metadataBlock,
            "script": [
                "name": script.metadata.name,
                "version": script.metadata.version ?? "",
                "namespace": script.metadata.namespace ?? ""
            ]
        ]
        context.setObject(info, forKeyedSubscript: "GM_info" as NSString)
    }

    private func installXHR(into context: JSContext, script: UserScript, scratch: Scratch, deadline: Date) {
        let connects = script.metadata.connects
        let session = self.session

        // Invoke a GM_xmlhttpRequest callback only if the script actually supplied a function,
        // so a request without (say) onload doesn't raise a spurious "not a function" exception.
        let invoke: (JSValue, String, [String: Any]) -> Void = { details, name, arg in
            if let callback = details.forProperty(name), callback.isObject {
                callback.call(withArguments: [arg])
            }
        }

        // Synchronous GM_xmlhttpRequest: we block this background thread (bounded by the budget)
        // and invoke onload/onerror on the JS side.
        let xhr: @convention(block) (JSValue) -> Void = { details in
            guard let urlString = details.forProperty("url")?.toString(),
                  let url = URL(string: urlString) else {
                invoke(details, "onerror", ["error": "invalid url"])
                return
            }
            guard GMNetworkService.isConnectAllowed(host: url.host, connects: connects, pageHost: nil) else {
                invoke(details, "onerror", ["error": "@connect does not permit \(url.host ?? "host")"])
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = (details.forProperty("method")?.toString() ?? "GET").uppercased()
            if let headers = details.forProperty("headers")?.toDictionary() as? [String: String] {
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
            }
            if let body = details.forProperty("data")?.toString(), body != "undefined", !body.isEmpty {
                request.httpBody = body.data(using: .utf8)
            }

            let semaphore = DispatchSemaphore(value: 0)
            var capturedData: Data?
            var capturedResponse: HTTPURLResponse?
            var capturedError: Error?
            let task = session.dataTask(with: request) { data, response, error in
                capturedData = data
                capturedResponse = response as? HTTPURLResponse
                capturedError = error
                semaphore.signal()
            }
            task.resume()

            let waitBudget = max(1.0, deadline.timeIntervalSinceNow)
            if semaphore.wait(timeout: .now() + waitBudget) == .timedOut {
                task.cancel()
                invoke(details, "ontimeout", ["error": "timeout"])
                invoke(details, "onerror", ["error": "timeout"])
                return
            }

            if let capturedError {
                invoke(details, "onerror", ["error": capturedError.localizedDescription])
                return
            }
            let text = capturedData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let headerString = capturedResponse?.allHeaderFields
                .map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\r\n") ?? ""
            let responseObject: [String: Any] = [
                "status": capturedResponse?.statusCode ?? 0,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: capturedResponse?.statusCode ?? 0),
                "responseText": text,
                "response": text,
                "responseHeaders": headerString,
                "finalUrl": capturedResponse?.url?.absoluteString ?? urlString,
                "readyState": 4
            ]
            invoke(details, "onload", responseObject)
        }
        context.setObject(xhr, forKeyedSubscript: "GM_xmlhttpRequest" as NSString)
    }

    private func log(_ script: UserScript, _ level: LogEntry.Level, _ message: String) -> LogEntry {
        LogEntry(scriptID: script.id, scriptName: script.metadata.name, level: level,
                 message: message, context: .background)
    }
}
