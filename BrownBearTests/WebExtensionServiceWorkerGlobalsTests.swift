//
//  WebExtensionServiceWorkerGlobalsTests.swift
//  BrownBearTests
//
//  Boots a REAL extension background context (the bundled brownbear-webext-background.js in a JSContext)
//  and asserts the service-worker web globals JavaScriptCore lacks are present and correct: `self`,
//  atob/btoa, TextEncoder/TextDecoder (UTF-8 round-trip incl. multi-byte), the chrome.runtime enums,
//  self.addEventListener + clients, and the native-backed fetch's host_permissions gate (a request to
//  an un-permitted host must fail closed). Regression coverage for the reported crashes:
//  "Can't find variable: self / TextEncoder", "…fetch.bind", "chrome.runtime.OnInstalledReason.INSTALL".
//

import XCTest
@testable import BrownBear

final class WebExtensionServiceWorkerGlobalsTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    private func backgroundRuntimeSource() throws -> String {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        guard let url else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeContext(background: String,
                             manifestJSON: String = #"{"manifest_version":3,"name":"Test","version":"1.0"}"#)
        throws -> WebExtensionBackgroundContext {
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "Test",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.swtest.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: manifestJSON,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testServiceWorkerGlobalsArePresentAndCorrect() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'globals') { return; }
          var enc = new TextEncoder().encode('héllo€');   // multi-byte: é (2), € (3)
          var dec = new TextDecoder('utf-8').decode(enc);
          sendResponse({
            hasSelf: (typeof self === 'object') && (self === globalThis),
            hasFetch: typeof fetch === 'function',
            hasTextEncoder: typeof TextEncoder === 'function',
            hasTextDecoder: typeof TextDecoder === 'function',
            encLen: enc.length,
            roundTrip: dec,
            btoaHi: btoa('hi'),
            installReason: chrome.runtime.OnInstalledReason.INSTALL,
            updateReason: chrome.runtime.OnInstalledReason.UPDATE,
            hasAddEventListener: typeof self.addEventListener === 'function',
            hasClientsClaim: typeof clients === 'object' && typeof clients.claim === 'function',
            hasRegistration: typeof registration === 'object',
            structuredCloneOk: (function () {
              if (typeof structuredClone !== 'function') { return false; }
              var src = { n: 1, d: new Date(5), a: [1, { x: 2 }], m: new Map([['k', 3]]) };
              src.self = src;   // circular
              var c = structuredClone(src);
              return c !== src && c.a[1] !== src.a[1] && c.a[1].x === 2
                && c.d.getTime() === 5 && c.m.get('k') === 3 && c.self === c;
            })()
          });
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "globals"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["hasSelf"] as? Bool, true)
        XCTAssertEqual(r["hasFetch"] as? Bool, true)
        XCTAssertEqual(r["hasTextEncoder"] as? Bool, true)
        XCTAssertEqual(r["hasTextDecoder"] as? Bool, true)
        // 'héllo€' = h(1) + é(2) + l(1) + l(1) + o(1) + €(3) = 9 UTF-8 bytes.
        XCTAssertEqual(r["encLen"] as? Int, 9)
        XCTAssertEqual(r["roundTrip"] as? String, "héllo€")
        XCTAssertEqual(r["btoaHi"] as? String, "aGk=")
        XCTAssertEqual(r["installReason"] as? String, "install")
        XCTAssertEqual(r["updateReason"] as? String, "update")
        XCTAssertEqual(r["hasAddEventListener"] as? Bool, true)
        XCTAssertEqual(r["hasClientsClaim"] as? Bool, true)
        XCTAssertEqual(r["hasRegistration"] as? Bool, true)
        XCTAssertEqual(r["structuredCloneOk"] as? Bool, true)
    }

    func testFetchHostGateFailsClosedWithoutHostPermission() async throws {
        // Manifest declares NO host_permissions, so a cross-origin fetch must be rejected (fail closed).
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'fetchGate') { return; }
          fetch('https://example.com/data.json')
            .then(function () { sendResponse({ rejected: false }); })
            .catch(function (e) { sendResponse({ rejected: true, message: String(e) }); });
          return true;   // async response
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "fetchGate"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["rejected"] as? Bool, true,
                       "fetch to an un-permitted host must fail closed (no host_permissions declared)")
        XCTAssertTrue((r["message"] as? String ?? "").contains("host permission"))
    }

    func testURLLocationPerformanceAndStorageSetAccessLevel() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'webglobals') { return; }
          var u = new URL('https://ex.com:8443/a/b?x=1&y=2#f');
          u.searchParams.set('x', '9');
          var sp = new URLSearchParams('a=1&a=2');
          var setAccessLevelOk = false;
          try { chrome.storage.session.setAccessLevel({ accessLevel: 'TRUSTED_AND_UNTRUSTED_CONTEXTS' });
                setAccessLevelOk = true; } catch (e) { setAccessLevelOk = false; }
          sendResponse({
            hasURL: typeof URL === 'function',
            hostname: u.hostname,
            port: u.port,
            origin: u.origin,
            href: u.href,
            getAllA: sp.getAll('a').join(','),
            hasLocation: typeof location === 'object' && typeof location.href === 'string',
            perfIsNumber: typeof performance.now() === 'number',
            setAccessLevelOk: setAccessLevelOk
          });
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "webglobals"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["hasURL"] as? Bool, true)
        XCTAssertEqual(r["hostname"] as? String, "ex.com")
        XCTAssertEqual(r["port"] as? String, "8443")
        XCTAssertEqual(r["origin"] as? String, "https://ex.com:8443")
        XCTAssertEqual(r["href"] as? String, "https://ex.com:8443/a/b?x=9&y=2#f")
        XCTAssertEqual(r["getAllA"] as? String, "1,2")
        XCTAssertEqual(r["hasLocation"] as? Bool, true)
        XCTAssertEqual(r["perfIsNumber"] as? Bool, true)
        XCTAssertEqual(r["setAccessLevelOk"] as? Bool, true)
    }

    func testRelativeFetchResolvesToPackagedSchemeNotInvalidURL() async throws {
        // ScriptCat fetches its own packaged files via a root-relative path (fetch('/src/content.js')).
        // That must resolve against the worker origin and hit the extension scheme handler (404 for a
        // missing file here), NOT reject as an unparseable bare URL — the "Unable to fetch …" bug.
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'relfetch') { return; }
          fetch('/does-not-exist.js').then(
            function (r) { sendResponse({ ok: true, status: r.status }); },
            function (e) { sendResponse({ ok: false, error: String((e && e.message) || e) }); });
          return true;   // async sendResponse
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "relfetch"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["ok"] as? Bool, true, "relative fetch must resolve, not reject: \(r)")
        XCTAssertEqual(r["status"] as? Int, 404, "missing packaged file → 404 response")
    }

    func testUserScriptsResetWorldConfigurationExists() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'reset') { return; }
          sendResponse({ isFn: typeof chrome.userScripts.resetWorldConfiguration === 'function' });
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "reset"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["isFn"] as? Bool, true)
    }
}
