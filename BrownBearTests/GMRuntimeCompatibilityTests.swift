//
//  GMRuntimeCompatibilityTests.swift
//  BrownBearTests
//
//  Runs the REAL injected runtime (brownbear-runtime.js) inside a JSContext with a mock native
//  bridge, and verifies the GM surface works for the kinds of scripts that break weaker engines:
//  typed storage, async GM.*, value-change listeners, @require code with GM access, resources
//  fetched then eval'd, and base64+eval ("obfuscated") code — all with GM_* in scope.
//
//  This also asserts the runtime resource is actually bundled into the app.
//

import JavaScriptCore
import XCTest
@testable import BrownBear

final class GMRuntimeCompatibilityTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    /// Locate the bundled runtime. The app's injection reads this same resource, so if it is
    /// missing the app itself is broken — hence a hard failure, not a skip.
    private func runtimeURL() -> URL? {
        Bundle.main.url(forResource: "brownbear-runtime", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-runtime", withExtension: "js")
    }

    private func runtimeSource() throws -> String {
        guard let url = runtimeURL() else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The injected runtime MUST be bundled into the app — otherwise userscript injection silently
    /// does nothing. This guards that invariant (and proves the GM tests below run for real).
    func testRuntimeIsBundled() {
        XCTAssertNotNil(runtimeURL(), "brownbear-runtime.js must be in the app bundle")
    }

    /// Run `script` through the real runtime and return the GM value store it produced
    /// (key → JSON-encoded value, exactly what GM_setValue persisted).
    private func runScript(_ script: String,
                           grants: [String] = defaultGrants,
                           requires: [String: String] = [:],
                           resources: [String: String] = [:]) throws -> [String: String] {
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }

        var store: [String: String] = [:]
        // Map asset URL → contents for fetchResource (requires keyed by their own URL).
        var assetByURL: [String: String] = [:]
        for (url, code) in requires { assetByURL[url] = code }
        for (_, url) in resources { /* resource urls resolved below */ assetByURL[url] = assetByURL[url] ?? "" }
        var resourceTextByURL: [String: String] = [:]
        for (name, text) in resources { resourceTextByURL["res://\(name)"] = text }

        // Build the script payload getScripts will return. @inject-into content keeps the script in the
        // ISOLATED world — this harness exercises the isolated GM bridge round-trip (it doesn't evaluate the
        // injectPageWorld payload a page-world script produces; that path is covered by Tests/JS/*).
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "test",
            "grants": grants, "grantNone": false, "noFrames": false, "injectInto": "content",
            "requires": Array(requires.keys),
            "resources": Dictionary(uniqueKeysWithValues: resources.keys.map { ($0, "res://\($0)") }),
            "source": script, "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]

        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"error\":\"bad body\"}" }
            let payload = body["payload"] as? [String: Any] ?? [:]
            switch api {
            case "getScripts":
                return reply([scriptData])
            case "GM_setValue":
                if let key = payload["key"] as? String, let value = payload["value"] as? String { store[key] = value }
                return reply(nil)
            case "GM_deleteValue":
                if let key = payload["key"] as? String { store.removeValue(forKey: key) }
                return reply(nil)
            case "fetchResource":
                let url = payload["url"] as? String ?? ""
                if let text = resourceTextByURL[url] ?? assetByURL[url] {
                    return reply(["text": text, "base64": Data(text.utf8).base64EncodedString(), "mimeType": "text/plain"])
                }
                return reply(["text": "", "base64": "", "mimeType": "text/plain"])
            default:
                return reply(nil)
            }
        }

        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        // JSContext drains promise microtasks at the end of evaluation; spin briefly as insurance
        // for any deferred job before reading the result.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        return store
    }

    /// Run a script and capture every line it sent to the log bridge — the `log` (console.*) and
    /// `GM_log` APIs. Proves foreground console output actually reaches native (the dashboard Logs).
    private func runForLogs(_ script: String,
                            grants: [String] = []) throws -> [(level: String, message: String)] {
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }
        var logs: [(level: String, message: String)] = []

        // @inject-into content: exercise the ISOLATED console→Logs forwarding (makeConsole). A granted
        // page/auto script runs in the page world (VM parity) and forwards console via the vault instead —
        // that page-world path is covered by Tests/JS/page-world-granted.test.js.
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "logtest",
            "grants": grants, "grantNone": false, "noFrames": false, "injectInto": "content",
            "requires": [String](), "resources": [String: String](),
            "source": script, "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]

        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"value\":null}" }
            let payload = body["payload"] as? [String: Any] ?? [:]
            switch api {
            case "getScripts":
                return reply([scriptData])
            case "log", "GM_log":
                logs.append((level: (payload["level"] as? String) ?? "info",
                             message: (payload["message"] as? String) ?? ""))
                return reply(nil)
            default:
                return reply(nil)
            }
        }

        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return logs
    }

    // MARK: - Tests

    func testConsoleLogReachesLogBridge() throws {
        // No grant needed — console works for every script, even @grant none.
        let logs = try runForLogs("console.log('hello', 42);")
        XCTAssertTrue(logs.contains { $0.level == "info" && $0.message == "hello 42" },
                      "console.log should forward to the native log bridge; got \(logs)")
    }

    func testConsoleLevelsMapToLogLevels() throws {
        let logs = try runForLogs("console.warn('w'); console.error('e'); console.debug('d');")
        XCTAssertTrue(logs.contains { $0.level == "warn" && $0.message == "w" })
        XCTAssertTrue(logs.contains { $0.level == "error" && $0.message == "e" })
        XCTAssertTrue(logs.contains { $0.level == "debug" && $0.message == "d" })
    }

    func testGMLogReachesLogBridge() throws {
        let logs = try runForLogs("GM_log('via gm');", grants: ["GM_log"])
        XCTAssertTrue(logs.contains { $0.message == "via gm" })
    }

    func testTypedStorageRoundTrip() throws {
        let store = try runScript("""
        GM_setValue('obj', {x: 1, y: [1, 2, 3]});
        GM_setValue('num', 42);
        GM_setValue('str', 'hello');
        GM_setValue('bool', true);
        var ok = GM_getValue('obj').y[2] === 3 && GM_getValue('num') === 42
              && GM_getValue('str') === 'hello' && GM_getValue('bool') === true;
        GM_setValue('ok', ok);
        """)
        XCTAssertEqual(store["ok"], "true")
        XCTAssertEqual(store["num"], "42")
    }

    func testValueChangeListenerFires() throws {
        let store = try runScript("""
        GM_addValueChangeListener('watched', function (key, oldVal, newVal, remote) {
          GM_setValue('captured', newVal);
        });
        GM_setValue('watched', 99);
        """)
        XCTAssertEqual(store["captured"], "99")
    }

    func testRemoteValueChangePropagation() throws {
        // Simulate native pushing a GM value change made by the SAME script in another frame/tab
        // (the keystone behind cross-frame/tab GM value sync): applyValueChange must update this
        // injection's cache (so GM_getValue sees it) and fire listeners with remote = true.
        let store = try runScript("""
        GM_addValueChangeListener('shared', function (key, oldVal, newVal, remote) {
          GM_setValue('capturedNew', newVal);
          GM_setValue('capturedRemote', remote);
        });
        window.__brownbear.applyValueChange(JSON.stringify({ token: 'tok', key: 'shared', old: null, new: '42' }));
        GM_setValue('readBack', GM_getValue('shared'));
        """)
        XCTAssertEqual(store["capturedNew"], "42")
        XCTAssertEqual(store["capturedRemote"], "true")
        XCTAssertEqual(store["readBack"], "42")
    }

    func testRemoteValueDeletePropagation() throws {
        let store = try runScript("""
        GM_setValue('shared', 7);
        GM_addValueChangeListener('shared', function (key, oldVal, newVal, remote) {
          GM_setValue('deletedRemote', remote);
          GM_setValue('newIsUndefined', newVal === undefined);
        });
        window.__brownbear.applyValueChange(JSON.stringify({ token: 'tok', key: 'shared', old: '7', new: null }));
        GM_setValue('readBackAfterDelete', GM_getValue('shared', 'MISSING'));
        """)
        XCTAssertEqual(store["deletedRemote"], "true")
        XCTAssertEqual(store["newIsUndefined"], "true")
        XCTAssertEqual(store["readBackAfterDelete"], "\"MISSING\"")
    }

    func testAsyncGMPromises() throws {
        let store = try runScript("""
        GM.setValue('a', 7).then(function () { return GM.getValue('a'); })
          .then(function (v) { GM_setValue('asyncResult', v); });
        """)
        XCTAssertEqual(store["asyncResult"], "7")
    }

    func testRequireCodeHasGMAccess() throws {
        let store = try runScript(
            "/* main body */ GM_setValue('mainRan', true);",
            requires: ["https://cdn.test/lib.js": "GM_setValue('fromRequire', 'yes');"])
        XCTAssertEqual(store["fromRequire"], "\"yes\"")
        XCTAssertEqual(store["mainRan"], "true")
    }

    func testInlinedRequireRunsWithoutBlockingFetchAndRevalidates() throws {
        // The warm-cache fast path (PR: inline cached @require into getScripts). Native delivers the
        // require body inline, so the script runs WITHOUT a blocking fetchResource at document-start.
        // We prove the inlined body is the source by making fetchResource return EMPTY for that URL —
        // if the script still sees the require, inlining worked — and assert fetchResource WAS still
        // called for the URL (the background freshness revalidation).
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }

        var store: [String: String] = [:]
        var fetchedURLs: [String] = []
        let requireURL = "https://cdn.test/inlined-lib.js"
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "inlinetest",
            "grants": Self.defaultGrants, "grantNone": false, "noFrames": false, "injectInto": "content",
            "requires": [requireURL],
            "inlinedRequires": [requireURL: "var REQVAL = 7;"],
            "resources": [String: String](),
            "source": "GM_setValue('fromRequire', REQVAL + 1);",
            "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]
        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"value\":null}" }
            let payload = body["payload"] as? [String: Any] ?? [:]
            switch api {
            case "getScripts": return reply([scriptData])
            case "GM_setValue":
                if let key = payload["key"] as? String, let value = payload["value"] as? String { store[key] = value }
                return reply(nil)
            case "fetchResource":
                fetchedURLs.append(payload["url"] as? String ?? "")
                return reply(["text": "", "base64": "", "mimeType": "text/plain"])   // empty: NOT the source
            default: return reply(nil)
            }
        }
        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store["fromRequire"], "8",
            "the inlined @require body ran (REQVAL=7 → 8) although fetchResource returned empty")
        XCTAssertTrue(fetchedURLs.contains(requireURL),
            "the inlined require is still revalidated in the background (fetchResource called for it)")
    }

    func testFetchedResourceThenEvalKeepsGMAccess() throws {
        // A resource fetched natively, then eval'd by the script — eval'd code must see GM_*.
        let store = try runScript(
            "eval(GM_getResourceText('payload'));",
            resources: ["payload": "GM_setValue('evaled', 7);"])
        XCTAssertEqual(store["evaled"], "7")
    }

    func testGMDownloadReturnsRealAbortHandle() throws {
        // GM_download(...).abort() must cancel the SAME native request: the abort call carries the
        // requestId from the original download (parity with TM/VM). The native cancellation itself is
        // integration-tested; here we prove the JS handle is real and correlated, not a no-op stub.
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }

        var downloadRequestId: String?
        var abortRequestId: String?
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "dltest",
            // @inject-into content: GM_download is page-world-safe now, so `auto` would route to the page
            // world (injectPageWorld), which this JSContext harness can't eval — pin to the isolated bridge
            // this test exercises.
            "grants": ["GM_download"], "grantNone": false, "noFrames": false, "injectInto": "content",
            "requires": [String](), "resources": [String: String](),
            "source": "var h = GM_download({ url: 'https://x.test/f.bin', name: 'f' }); h.abort();",
            "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]
        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"value\":null}" }
            let payload = body["payload"] as? [String: Any] ?? [:]
            switch api {
            case "getScripts": return reply([scriptData])
            case "GM_download": downloadRequestId = payload["requestId"] as? String; return reply(nil)
            case "GM_downloadAbort": abortRequestId = payload["requestId"] as? String; return reply(nil)
            default: return reply(nil)
            }
        }
        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(downloadRequestId, "GM_download issued a native request")
        XCTAssertEqual(abortRequestId, downloadRequestId,
                       "abort() targets the SAME requestId as the download (a real handle, not a no-op)")
    }

    func testGMDownloadPromiseExposesAbort() throws {
        // GM.download(...) returns a Promise; .abort() on it must cancel the SAME download (TM/VM
        // parity) — it was silently dropped before. Mirrors the GM.xmlHttpRequest promise.abort.
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }
        var downloadRequestId: String?
        var abortRequestId: String?
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "dlpromise",
            // @inject-into content: GM_download + GM_setValue are both page-world-safe now, so `auto` would
            // route to the page world (injectPageWorld) which this JSContext harness can't eval — pin to the
            // isolated bridge this test exercises.
            "grants": ["GM_download", "GM_setValue"], "grantNone": false, "noFrames": false, "injectInto": "content",
            "requires": [String](), "resources": [String: String](),
            "source": "var p = GM.download({ url: 'https://x.test/f.bin', name: 'f' });"
                + " GM_setValue('abortType', typeof p.abort); p.abort();",
            "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]
        var store: [String: String] = [:]
        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"value\":null}" }
            let payload = body["payload"] as? [String: Any] ?? [:]
            switch api {
            case "getScripts": return reply([scriptData])
            case "GM_download": downloadRequestId = payload["requestId"] as? String; return reply(nil)
            case "GM_downloadAbort": abortRequestId = payload["requestId"] as? String; return reply(nil)
            case "GM_setValue":
                if let key = payload["key"] as? String, let value = payload["value"] as? String { store[key] = value }
                return reply(nil)
            default: return reply(nil)
            }
        }
        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store["abortType"], "\"function\"", "GM.download() promise exposes abort()")
        XCTAssertNotNil(downloadRequestId)
        XCTAssertEqual(abortRequestId, downloadRequestId, "promise.abort() cancels the same download")
    }

    func testGMOpenInTabHandleClosesAndFiresOnClose() throws {
        // GM_openInTab returns a REAL handle (TM/VM parity): closed flips + onclose fires when native
        // reports the tab closed, and close() routes GM_closeTab with the same openId. (The native tab
        // open/close itself is integration-tested.)
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }

        var store: [String: String] = [:]
        var openId: String?
        var closeOpenId: String?
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "tabtest",
            "grants": ["GM_openInTab", "GM_setValue"], "grantNone": false, "noFrames": false, "injectInto": "auto",
            "requires": [String](), "resources": [String: String](),
            "source": "window.__t = GM_openInTab('https://x.test/');"
                + " window.__t.onclose = function () { GM_setValue('closedFired', true); };",
            "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]
        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"value\":null}" }
            let payload = body["payload"] as? [String: Any] ?? [:]
            switch api {
            case "getScripts": return reply([scriptData])
            case "GM_openInTab": openId = payload["openId"] as? String; return reply(nil)
            case "GM_closeTab": closeOpenId = payload["openId"] as? String; return reply(nil)
            case "GM_setValue":
                if let key = payload["key"] as? String, let value = payload["value"] as? String { store[key] = value }
                return reply(nil)
            default: return reply(nil)
            }
        }
        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(openId, "GM_openInTab issued a native open carrying an openId")
        XCTAssertEqual(context.evaluateScript("window.__t.closed")?.toBool(), false, "handle starts open")

        // Native reports the tab closed → handle flips closed and fires onclose (which set the value).
        context.evaluateScript("window.__brownbear.dispatchTabClosed('\(openId ?? "")');")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(context.evaluateScript("window.__t.closed")?.toBool(), true, "closed flips on tab close")
        XCTAssertEqual(store["closedFired"], "true", "onclose fired when the tab closed")

        // close() routes GM_closeTab with the open's openId (a real close, not a no-op).
        context.evaluateScript("window.__t.close();")
        XCTAssertEqual(closeOpenId, openId, "close() targets the same openId as the open")
    }

    func testGMAddStyleAppliesConstructedStylesheetForCSPResilience() throws {
        // GM_addStyle must also apply a CONSTRUCTED stylesheet (adoptedStyleSheets), so the script's CSS
        // lands even when a page's strict style-src refuses the isolated-world <style> element.
        let runtime = try runtimeSource()
        guard let context = JSContext() else { throw XCTSkip("no JSContext") }
        let scriptData: [String: Any] = [
            // @inject-into content exercises the ISOLATED GM_addStyle constructed-stylesheet fallback; the
            // page-world GM_addStyle (also constructed-sheet) is covered by page-world-granted.test.js.
            "token": "tok", "runAt": "document-start", "name": "styletest",
            "grants": ["GM_addStyle"], "grantNone": false, "noFrames": false, "injectInto": "content",
            "requires": [String](), "resources": [String: String](),
            "source": "GM_addStyle('body { color: red }');",
            "values": [String: String](), "info": ["scriptHandler": "BrownBear"]
        ]
        let bridge: @convention(block) (String) -> String = { bodyJSON in
            func reply(_ value: Any?) -> String {
                let payload: [String: Any] = ["value": value ?? NSNull()]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"value\":null}".utf8)
                return String(decoding: data, as: UTF8.self)
            }
            guard let data = bodyJSON.data(using: .utf8),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let api = body["api"] as? String else { return "{\"value\":null}" }
            return api == "getScripts" ? reply([scriptData]) : reply(nil)
        }
        installDOMStubs(context)
        context.setObject(bridge, forKeyedSubscript: "__nativeBridge" as NSString)
        context.evaluateScript(Self.bridgePrelude)
        context.evaluateScript(runtime)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(context.evaluateScript("document.adoptedStyleSheets.length")?.toInt32(), 1,
                       "GM_addStyle adds a constructed stylesheet (CSP-resilient) to adoptedStyleSheets")
        XCTAssertEqual(context.evaluateScript("document.adoptedStyleSheets[0].cssText")?.toString(),
                       "body { color: red }", "the constructed sheet carries the script's CSS")
    }

    func testObfuscatedBase64EvalScript() throws {
        // "Obfuscated": base64-encoded GM_setValue call, decoded and eval'd at runtime.
        // base64 of: GM_setValue('b64', 123);
        let store = try runScript("""
        var payload = 'R01fc2V0VmFsdWUoJ2I2NCcsIDEyMyk7';
        eval(atob(payload));
        """)
        XCTAssertEqual(store["b64"], "123")
    }

    func testComputedIndirectionStillWorks() throws {
        let store = try runScript("""
        (function () {
          var k = 'ob' + 'f';
          var v = 6 * 7;
          GM_setValue(k, v);
        })();
        """)
        XCTAssertEqual(store["obf"], "42")
    }

    // MARK: - Harness

    private static let defaultGrants = [
        "GM_setValue", "GM_getValue", "GM_deleteValue", "GM_listValues",
        "GM_getResourceText", "GM_getResourceURL", "GM_addValueChangeListener",
        "GM_removeValueChangeListener", "GM_log"
    ]

    private func installDOMStubs(_ context: JSContext) {
        let atob: @convention(block) (String) -> String = { encoded in
            guard let data = Data(base64Encoded: encoded) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        context.setObject(atob, forKeyedSubscript: "__atob" as NSString)
    }

    /// Sets up window/document/location/webkit so the runtime IIFE can execute headlessly.
    private static let bridgePrelude = """
    var window = this;
    window.atob = __atob;
    window.location = { href: "https://example.test/page" };
    window.top = window;
    window.self = window;
    window.console = { log: function () {}, info: function () {}, warn: function () {}, error: function () {}, debug: function () {} };
    var console = window.console;
    window.addEventListener = function () {};
    window.document = {
      readyState: "complete",
      addEventListener: function () {},
      createElement: function () { return { textContent: "", setAttribute: function () {}, appendChild: function () {} }; },
      head: { appendChild: function () {} },
      documentElement: { appendChild: function () {} },
      adoptedStyleSheets: []
    };
    var document = window.document;
    window.CSSStyleSheet = function () { this.replaceSync = function (css) { this.cssText = css; }; };
    window.webkit = { messageHandlers: { brownbear: { postMessage: function (body) {
      return new Promise(function (resolve, reject) {
        var raw = __nativeBridge(JSON.stringify(body));
        var parsed = JSON.parse(raw);
        if (parsed && parsed.error) { reject(new Error(parsed.error)); } else { resolve(parsed.value); }
      });
    } } } };
    """
}
