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

    /// The bundled runtime source. Fails (and flags a missing resource) if it isn't in the bundle.
    private func runtimeSource() throws -> String {
        guard let url = Bundle.main.url(forResource: "brownbear-runtime", withExtension: "js")
                ?? Bundle(for: Self.self).url(forResource: "brownbear-runtime", withExtension: "js") else {
            throw XCTSkip("brownbear-runtime.js is not bundled in this configuration")
        }
        return try String(contentsOf: url, encoding: .utf8)
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

        // Build the script payload getScripts will return.
        let scriptData: [String: Any] = [
            "token": "tok", "runAt": "document-start", "name": "test",
            "grants": grants, "grantNone": false, "noFrames": false, "injectInto": "auto",
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

    // MARK: - Tests

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

    func testFetchedResourceThenEvalKeepsGMAccess() throws {
        // A resource fetched natively, then eval'd by the script — eval'd code must see GM_*.
        let store = try runScript(
            "eval(GM_getResourceText('payload'));",
            resources: ["payload": "GM_setValue('evaled', 7);"])
        XCTAssertEqual(store["evaled"], "7")
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
      documentElement: { appendChild: function () {} }
    };
    var document = window.document;
    window.webkit = { messageHandlers: { brownbear: { postMessage: function (body) {
      return new Promise(function (resolve, reject) {
        var raw = __nativeBridge(JSON.stringify(body));
        var parsed = JSON.parse(raw);
        if (parsed && parsed.error) { reject(new Error(parsed.error)); } else { resolve(parsed.value); }
      });
    } } } };
    """
}
