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

import CryptoKit
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
        /// GM_addValueChangeListener registrations made during this run: id -> (key, fn). Fired
        /// (remote: false) when GM_setValue(s)/deleteValue(s) changes that key, so a background script's
        /// own value-change listeners work within the run (there is no live cross-context here).
        var valueListeners: [Int: (key: String, fn: JSValue)] = [:]
        var listenerSeq = 0
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
        var changes: [GMValueChange] = []
        if !sets.isEmpty {
            let olds = await valueStore.setValuesReturningOld(scriptID: script.id, entries: sets)
            changes += olds.map { GMValueChange(key: $0.key, old: $0.old, new: sets[$0.key]) }
        }
        if !deletes.isEmpty {
            let olds = await valueStore.deleteValuesReturningOld(scriptID: script.id, keys: deletes)
            changes += olds.map { GMValueChange(key: $0.key, old: $0.old, new: nil) }
        }
        // If a page is open running this script (a foreground @crontab run), live-sync the changed
        // values into it so GM_getValue / value-change listeners see them without a reload (TM/VM
        // parity). The foreground InjectionOrchestrator observes this; nothing observes it with the app
        // closed (the usual background case), so it's a no-op exactly when there's no page to update.
        if !changes.isEmpty {
            NotificationCenter.default.post(
                name: .brownBearGMValueChangedExternally,
                object: GMValueChangeBroadcast(scriptID: script.id, changes: changes))
        }

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
        // IndexedDB (JSC has none): install the engine + rehydrate this script's snapshot before its
        // body runs. This one-shot runner has no setTimeout, so the JS auto-save can't debounce — we
        // flush once after the body (and its microtask-scheduled IndexedDB work) has drained.
        BrownBearIDBStore.shared.install(into: context, namespace: .script(script.id.uuidString))

        // Wrap in a function so a background script using a top-level `return` (common in ScriptCat
        // background scripts) is valid — bare top-level `return` is a SyntaxError. The body starts on
        // line 1 of the wrapper so error line numbers still line up with the script source.
        let wrappedBody = "(function(){" + script.executableBody + "\n})();"
        context.evaluateScript(wrappedBody, withSourceURL: URL(string: "brownbear://\(script.id.uuidString).user.js"))
        BrownBearIDBStore.shared.flush(context: context)   // persist any IndexedDB writes the run made

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

          // JavaScriptCore has no Web Crypto; many background scripts (ScriptCat sign-in helpers,
          // crypto-using libs) reach for crypto.getRandomValues / randomUUID / subtle.digest. Back
          // them with native secure-random + CryptoKit so those scripts run instead of throwing
          // "Can't find variable: crypto".
          if (!this.crypto) {
            this.crypto = {
              getRandomValues: function (arr) {
                if (!arr || typeof arr.length !== 'number') {
                  throw new TypeError('getRandomValues expects an integer TypedArray');
                }
                var byteLen = arr.length * (arr.BYTES_PER_ELEMENT || 1);
                // Web Crypto quota: >65536 bytes fails closed (never silently short/zero-fill).
                if (byteLen > 65536) {
                  var qErr = new Error('getRandomValues: quota (65536 bytes) exceeded');
                  qErr.name = 'QuotaExceededError';
                  throw qErr;
                }
                var bytes = __bbCryptoRandom(byteLen);
                var view = new Uint8Array(arr.buffer, arr.byteOffset || 0, byteLen);
                for (var i = 0; i < byteLen && i < bytes.length; i++) { view[i] = bytes[i] & 0xff; }
                return arr;
              },
              randomUUID: function () { return __bbCryptoUUID(); },
              subtle: {
                digest: function (algo, data) {
                  var name = (typeof algo === 'string') ? algo : (algo && algo.name) || '';
                  var view = (data instanceof ArrayBuffer) ? new Uint8Array(data)
                    : (data && data.buffer ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
                       : new Uint8Array(data || []));
                  var out = __bbCryptoDigest(name, Array.prototype.slice.call(view));
                  if (!out) { return Promise.reject(new Error('Unsupported digest: ' + name)); }
                  return Promise.resolve(new Uint8Array(out).buffer);
                }
              }
            };
          }

          // ScriptCat-style background scripts load dependencies with importScripts(); back it with a
          // synchronous @connect-gated native fetch (same budget/gating as GM_xmlhttpRequest here).
          if (typeof this.importScripts !== 'function') {
            this.importScripts = function () {
              for (var i = 0; i < arguments.length; i++) {
                var src = __bbImportScript(String(arguments[i]));
                if (src) { (0, eval)(src); }
              }
            };
          }
        })();
        """)

        // Honest, device-derived inputs for the navigator/location polyfills the bundle installs below.
        // A background userscript has no page, so `location` defaults to about:blank; navigator mirrors
        // the running OS. Set before the bundle so its `if (absent)` guards pick these up.
        context.setObject(HeadlessEnvironment.userAgent, forKeyedSubscript: "__bbUserAgent" as NSString)
        context.setObject(HeadlessEnvironment.language, forKeyedSubscript: "__bbLanguage" as NSString)
        context.setObject("about:blank", forKeyedSubscript: "__bbHeadlessLocation" as NSString)

        // URL / URLSearchParams / performance / navigator / location — web globals JavaScriptCore lacks.
        // Loaded from a node-validated bundled resource (regex-heavy, so embedding it as a Swift string
        // literal would be escape-hell and unchecked). Background userscripts otherwise throw
        // "Can't find variable: URL / navigator / location".
        if let url = Bundle.main.url(forResource: "brownbear-jscore-globals", withExtension: "js")
            ?? Bundle.main.url(forResource: "brownbear-jscore-globals", withExtension: "js", subdirectory: "JS"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(source, withSourceURL: url)
        }
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

        // Invoke any GM_addValueChangeListener registered for `key` with (key, old, new, remote:false).
        func fireValueListeners(_ key: String, _ oldRaw: String?, _ newRaw: String?) {
            guard !scratch.valueListeners.isEmpty else { return }
            let oldVal: Any = oldRaw.flatMap(parse) ?? NSNull()
            let newVal: Any = newRaw.flatMap(parse) ?? NSNull()
            for (_, entry) in scratch.valueListeners where entry.key == key {
                entry.fn.call(withArguments: [key, oldVal, newVal, false])
            }
        }
        // Write `key` to the cache (nil value deletes), recording the change and firing listeners.
        func writeValue(_ key: String, _ value: JSValue?) {
            let oldRaw = scratch.cache[key]
            scratch.touched.insert(key)
            var newRaw: String?
            if let value, !value.isUndefined {
                let encoded = stringify(value)
                scratch.cache[key] = encoded
                newRaw = encoded
            } else {
                scratch.cache.removeValue(forKey: key)
            }
            fireValueListeners(key, oldRaw, newRaw)
        }

        let getValue: @convention(block) (String, JSValue?) -> Any? = { key, fallback in
            if let raw = scratch.cache[key], let parsed = parse(raw) { return parsed }
            return fallback
        }
        context.setObject(getValue, forKeyedSubscript: "GM_getValue" as NSString)

        let setValue: @convention(block) (String, JSValue?) -> Void = { key, value in writeValue(key, value) }
        context.setObject(setValue, forKeyedSubscript: "GM_setValue" as NSString)

        let deleteValue: @convention(block) (String) -> Void = { key in
            let oldRaw = scratch.cache[key]
            scratch.touched.insert(key)
            scratch.cache.removeValue(forKey: key)
            fireValueListeners(key, oldRaw, nil)
        }
        context.setObject(deleteValue, forKeyedSubscript: "GM_deleteValue" as NSString)

        let listValues: @convention(block) () -> [String] = {
            Array(scratch.cache.keys)
        }
        context.setObject(listValues, forKeyedSubscript: "GM_listValues" as NSString)

        // Bulk value APIs (Tampermonkey/Violentmonkey) — ScriptCat background scripts use these for
        // batch reads/writes; their absence threw "GM_setValues is not a function" and killed the run.
        let getValues: @convention(block) (JSValue?) -> [String: Any] = { keys in
            var out: [String: Any] = [:]
            for key in (keys?.toArray() as? [String]) ?? [] {
                if let raw = scratch.cache[key], let parsed = parse(raw) { out[key] = parsed }
            }
            return out
        }
        context.setObject(getValues, forKeyedSubscript: "GM_getValues" as NSString)

        let setValues: @convention(block) (JSValue?) -> Void = { obj in
            guard let obj, obj.isObject, let dict = obj.toDictionary() as? [String: Any] else { return }
            for key in dict.keys { writeValue(key, obj.objectForKeyedSubscript(key)) }
        }
        context.setObject(setValues, forKeyedSubscript: "GM_setValues" as NSString)

        let deleteValues: @convention(block) (JSValue?) -> Void = { keys in
            for key in (keys?.toArray() as? [String]) ?? [] {
                let oldRaw = scratch.cache[key]
                scratch.touched.insert(key)
                scratch.cache.removeValue(forKey: key)
                fireValueListeners(key, oldRaw, nil)
            }
        }
        context.setObject(deleteValues, forKeyedSubscript: "GM_deleteValues" as NSString)

        let addValueChangeListener: @convention(block) (String, JSValue?) -> Int = { key, fn in
            guard let fn, !fn.isUndefined else { return -1 }
            scratch.listenerSeq += 1
            scratch.valueListeners[scratch.listenerSeq] = (key: key, fn: fn)
            return scratch.listenerSeq
        }
        context.setObject(addValueChangeListener, forKeyedSubscript: "GM_addValueChangeListener" as NSString)

        let removeValueChangeListener: @convention(block) (Int) -> Void = { id in
            scratch.valueListeners.removeValue(forKey: id)
        }
        context.setObject(removeValueChangeListener, forKeyedSubscript: "GM_removeValueChangeListener" as NSString)

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
            if let headers = details.forProperty("headers")?.toDictionary() {
                // Coerce each value to a string so one non-string header (e.g. {"X-Count": 5})
                // doesn't make the whole-map `as? [String: String]` cast fail and drop ALL headers.
                for (field, value) in headers {
                    request.setValue(String(describing: value), forHTTPHeaderField: "\(field)")
                }
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
            // Re-validate redirects against @connect (no page host in the background) so a 3xx to an
            // undeclared host is refused, matching the foreground GMNetworkService guard.
            task.delegate = GMRedirectGuard(connects: connects, pageHost: nil)
            task.resume()

            // Reserve headroom before the deadline so the post-run GM value flush + setTaskCompleted
            // still happen even if this request runs long (don't burn the entire remaining budget).
            let waitBudget = max(0.5, deadline.timeIntervalSinceNow - 2.0)
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

        // --- Web Crypto backing (JavaScriptCore ships none) -------------------------------------
        // Secure random bytes (SystemRandomNumberGenerator is cryptographically secure on Apple OSes).
        let cryptoRandom: @convention(block) (Int) -> [Int] = { count in
            let n = max(0, min(count, 65_536))
            return (0..<n).map { _ in Int(UInt8.random(in: 0...255)) }
        }
        context.setObject(cryptoRandom, forKeyedSubscript: "__bbCryptoRandom" as NSString)

        let cryptoUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        context.setObject(cryptoUUID, forKeyedSubscript: "__bbCryptoUUID" as NSString)

        // crypto.subtle.digest via CryptoKit — SHA-1/256/384/512. Returns the digest bytes, or nil
        // (→ a rejected promise on the JS side) for an unsupported algorithm.
        let cryptoDigest: @convention(block) (String, [Int]) -> [Int]? = { algo, bytes in
            let data = Data(bytes.map { UInt8(truncatingIfNeeded: $0) })
            switch algo.lowercased().replacingOccurrences(of: "-", with: "") {
            case "sha256": return Array(SHA256.hash(data: data)).map { Int($0) }
            case "sha384": return Array(SHA384.hash(data: data)).map { Int($0) }
            case "sha512": return Array(SHA512.hash(data: data)).map { Int($0) }
            case "sha1": return Array(Insecure.SHA1.hash(data: data)).map { Int($0) }
            default: return nil
            }
        }
        context.setObject(cryptoDigest, forKeyedSubscript: "__bbCryptoDigest" as NSString)

        // --- importScripts (ScriptCat-style background dep loading) -----------------------------
        // Synchronous @connect-gated fetch (mirrors the synchronous-XHR pattern above; the OS task
        // budget is the outer bound). Returns the source for the JS side to eval, or nil on
        // block/failure. The completion fires on a URLSession queue, so the semaphore can't deadlock
        // the JSContext thread.
        let importScript: @convention(block) (String) -> String? = { [weak self] urlString in
            guard let self, let url = URL(string: urlString) else { return nil }
            guard GMNetworkService.isConnectAllowed(host: url.host, connects: connects, pageHost: nil) else {
                scratch.logs.append(self.log(script, .warn,
                    "importScripts blocked by @connect: \(url.host ?? urlString)"))
                return nil
            }
            let semaphore = DispatchSemaphore(value: 0)
            var source: String?
            // Bound the wait (and the URLSession timeout) to the remaining run budget, reserving the same
            // ~2s headroom GM_xmlhttpRequest uses — otherwise a slow/hung host blocks the JSContext queue
            // up to 20s past the deadline, starving the post-run value flush + setTaskCompleted.
            let waitBudget = max(0.5, deadline.timeIntervalSinceNow - 2.0)
            var request = URLRequest(url: url)
            request.timeoutInterval = min(20, waitBudget)
            let task = URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data { source = String(data: data, encoding: .utf8) }
                semaphore.signal()
            }
            task.delegate = GMRedirectGuard(connects: connects, pageHost: nil)
            task.resume()
            if semaphore.wait(timeout: .now() + waitBudget) == .timedOut {
                task.cancel()
                scratch.logs.append(self.log(script, .warn,
                    "importScripts timed out (deadline): \(url.host ?? urlString)"))
                return nil
            }
            return source
        }
        context.setObject(importScript, forKeyedSubscript: "__bbImportScript" as NSString)
    }

    private func log(_ script: UserScript, _ level: LogEntry.Level, _ message: String) -> LogEntry {
        LogEntry(scriptID: script.id, scriptName: script.metadata.name, level: level,
                 message: message, context: .background)
    }
}
