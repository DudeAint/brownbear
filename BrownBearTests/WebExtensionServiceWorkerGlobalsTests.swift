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
                             manifestJSON: String = #"{"manifest_version":3,"name":"Test","version":"1.0"}"#,
                             installReason: String? = nil,
                             previousVersion: String? = nil)
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
                     messages: [:],
                     installReason: installReason,
                     previousVersion: previousVersion)
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

    func testClassicSWTopLevelDeclarationsAreVisibleToImportScriptsChunks() async throws {
        // Chrome evaluates a classic service worker at GLOBAL scope, so the worker's top-level
        // `var`/`function` are global bindings visible to importScripts() chunks — which our shim
        // evaluates via `(0, eval)(src)` at global scope. Wrapping the source in an IIFE made them
        // closure-local and INVISIBLE to those chunks, breaking real bundles (Violentmonkey's `M`,
        // Best AdBlocker's `fn`). This probe uses the SAME `(0, eval)` mechanism importScripts uses,
        // so it discriminates global-scope (visible) from the old IIFE wrapping (MISSING).
        let context = try makeContext(background: """
        var topLevelVar = 42;
        function topLevelFn() { return 'fn-ok'; }
        var crossChunk = (0, eval)('(typeof topLevelVar !== "undefined" ? String(topLevelVar) : "MISSING")'
          + ' + ":" + (typeof topLevelFn === "function" ? topLevelFn() : "NOFN")');
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'scope') { return; }
          sendResponse({ crossChunk: crossChunk });
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "scope"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the worker must register its listener")
        XCTAssertEqual(r["crossChunk"] as? String, "42:fn-ok",
                       "top-level SW symbols must be visible to importScripts-style (0,eval) chunks (Chrome global scope)")
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

    func testContentScriptMatchDoesNotGrantHostFetchAccess() async throws {
        // SECURITY: a content_scripts match for example.com must NOT confer host access. In Chrome,
        // content_scripts.matches only allows INJECTION; cookie/fetch/scripting require host_permissions.
        // The manifest below has a content-script match for example.com but NO host_permissions, so a
        // worker fetch to example.com must still fail closed (regression guard for the privilege-
        // escalation where effectiveHostPatterns widened the gate with content-script matches).
        let manifest = #"{"manifest_version":3,"name":"T","version":"1.0","content_scripts":[{"matches":["https://example.com/*"],"js":["c.js"]}]}"#
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'fetchGate') { return; }
          fetch('https://example.com/data.json')
            .then(function () { sendResponse({ rejected: false }); })
            .catch(function (e) { sendResponse({ rejected: true }); });
          return true;
        });
        """, manifestJSON: manifest)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "fetchGate"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["rejected"] as? Bool, true, "a content_scripts match must NOT grant host fetch access")
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

    func testCryptoSubtleHmacAesGcmPbkdf2RoundTrip() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'subtle') { return; }
          (async function () {
            var enc = new TextEncoder();
            var hk = await crypto.subtle.importKey('raw', enc.encode('secret-key'),
                       { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
            var sig = await crypto.subtle.sign('HMAC', hk, enc.encode('hello'));
            var ok = await crypto.subtle.verify('HMAC', hk, sig, enc.encode('hello'));
            var bad = await crypto.subtle.verify('HMAC', hk, sig, enc.encode('tampered'));
            var ak = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
            var iv = crypto.getRandomValues(new Uint8Array(12));
            var ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv }, ak, enc.encode('secret-msg'));
            var pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv }, ak, ct);
            var pk = await crypto.subtle.importKey('raw', enc.encode('password'), { name: 'PBKDF2' }, false, ['deriveBits']);
            var bits = await crypto.subtle.deriveBits(
                       { name: 'PBKDF2', salt: enc.encode('salt'), iterations: 1000, hash: 'SHA-256' }, pk, 256);
            var ck = await crypto.subtle.importKey('raw', new Uint8Array(16), { name: 'AES-CBC' }, false, ['encrypt', 'decrypt']);
            var civ = crypto.getRandomValues(new Uint8Array(16));
            var cbcCt = await crypto.subtle.encrypt({ name: 'AES-CBC', iv: civ }, ck, enc.encode('cbc-msg'));
            var cbcPt = await crypto.subtle.decrypt({ name: 'AES-CBC', iv: civ }, ck, cbcCt);
            sendResponse({ sigLen: sig.byteLength, verifyOk: ok, verifyBad: bad,
                           roundtrip: new TextDecoder().decode(pt), bitsLen: bits.byteLength,
                           cbc: new TextDecoder().decode(cbcPt) });
          })().catch(function (e) { sendResponse({ error: String((e && e.message) || e) }); });
          return true;
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "subtle"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "subtle should respond")
        XCTAssertNil(r["error"], "no crypto error: \(r)")
        XCTAssertEqual(r["sigLen"] as? Int, 32, "HMAC-SHA256 is 32 bytes")
        XCTAssertEqual(r["verifyOk"] as? Bool, true)
        XCTAssertEqual(r["verifyBad"] as? Bool, false)
        XCTAssertEqual(r["roundtrip"] as? String, "secret-msg")
        XCTAssertEqual(r["bitsLen"] as? Int, 32, "256-bit derived = 32 bytes")
        XCTAssertEqual(r["cbc"] as? String, "cbc-msg", "AES-CBC encrypt→decrypt round-trips")
    }

    func testRegisterContentScriptsExistsAndGatesOnPermission() async throws {
        // The default manifest has no "scripting" permission, so register must reject (fail closed) —
        // proving both that the method exists (ScriptCat's "is not a function" is gone) and the gate works.
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'regcs') { return; }
          var isFn = typeof chrome.scripting.registerContentScripts === 'function';
          chrome.scripting.registerContentScripts([{ id: 's1', matches: ['*://*/*'], js: ['cs.js'] }]).then(
            function () { sendResponse({ isFn: isFn, rejected: false }); },
            function (e) { sendResponse({ isFn: isFn, rejected: true }); });
          return true;
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "regcs"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["isFn"] as? Bool, true)
        XCTAssertEqual(r["rejected"] as? Bool, true, "register without the scripting permission must reject")
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

    // MARK: - chrome.runtime.onInstalled (reason + previousVersion)

    /// An 'update' boot must deliver `{reason:'update', previousVersion:<old>}` so an extension can run
    /// its version-gated migration — the most common reason real extensions read onInstalled at all.
    func testOnInstalledFiresUpdateReasonWithPreviousVersion() async throws {
        let context = try makeContext(background: """
        globalThis.__installDetails = null;
        chrome.runtime.onInstalled.addListener(function (details) { globalThis.__installDetails = details; });
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (msg && msg.check === 'installed') { sendResponse(globalThis.__installDetails || { reason: 'none' }); }
        });
        """, installReason: "update", previousVersion: "1.0")
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "installed"], sender: [:])
        let details = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(details["reason"] as? String, "update")
        XCTAssertEqual(details["previousVersion"] as? String, "1.0")
    }

    /// A fresh 'install' boot delivers `{reason:'install'}` with NO previousVersion (Chrome omits it).
    func testOnInstalledFiresInstallReasonWithoutPreviousVersion() async throws {
        let context = try makeContext(background: """
        globalThis.__installDetails = null;
        chrome.runtime.onInstalled.addListener(function (details) { globalThis.__installDetails = details; });
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (msg && msg.check === 'installed') { sendResponse(globalThis.__installDetails || { reason: 'none' }); }
        });
        """, installReason: "install")
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "installed"], sender: [:])
        let details = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(details["reason"] as? String, "install")
        XCTAssertNil(details["previousVersion"])
    }

    /// A same-version reboot fires NO onInstalled at all (installReason nil), so first-run setup —
    /// opening a welcome tab, seeding storage — does not re-run on every launch.
    func testOnInstalledDoesNotFireOnSameVersionReboot() async throws {
        let context = try makeContext(background: """
        globalThis.__installFired = false;
        chrome.runtime.onInstalled.addListener(function () { globalThis.__installFired = true; });
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (msg && msg.check === 'installed') { sendResponse({ fired: globalThis.__installFired }); }
        });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["check": "installed"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["fired"] as? Bool, false)
    }

    // MARK: - runtime.sendMessage no-listener reporting (drives the sender's lastError)

    /// A worker that registers NO chrome.runtime.onMessage listener must report `{__bbNoListener:true}`,
    /// so the runtime can surface Chrome's "Could not establish connection. Receiving end does not
    /// exist." on the sender rather than silently resolving undefined.
    func testWorkerWithNoMessageListenerReportsNoListener() async throws {
        let context = try makeContext(background: "var ready = true;   // no onMessage listener")
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["any": true], sender: [:])
        XCTAssertEqual(response?["__bbNoListener"] as? Bool, true)
    }

    /// A listener that exists but declines (returns undefined synchronously) is a receiving end — the
    /// dispatch resolves to nil (received-but-declined), NOT the no-listener marker. Only the total
    /// absence of a listener raises no-receiver, exactly like Chrome.
    func testWorkerWithDecliningListenerIsNotNoListener() async throws {
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) { /* declines */ });
        """)
        defer { context.shutdown() }
        let response = await context.deliverRuntimeMessage(message: ["any": true], sender: [:])
        XCTAssertNil(response)
    }

    // MARK: - chrome.identity namespace + getRedirectURL

    /// chrome.identity must exist (so an OAuth extension doesn't crash on an undefined namespace) and
    /// getRedirectURL must produce Chrome's exact value: https://<id>.chromiumapp.org/<path>, with a
    /// leading slash on the path collapsed and an omitted path yielding the bare origin + "/".
    func testIdentityNamespaceAndRedirectURL() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let context = try makeContext(background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'identity') { return; }
          sendResponse({
            hasIdentity: typeof chrome.identity === 'object',
            hasLaunch: typeof chrome.identity.launchWebAuthFlow === 'function',
            hasAuthToken: typeof chrome.identity.getAuthToken === 'function',
            hasOnSignInChanged: typeof chrome.identity.onSignInChanged.addListener === 'function',
            redirect: chrome.identity.getRedirectURL('cb'),
            redirectSlash: chrome.identity.getRedirectURL('/cb'),
            redirectEmpty: chrome.identity.getRedirectURL()
          });
        });
        """)
        defer { context.shutdown() }
        let r = try XCTUnwrap(
            (await context.deliverRuntimeMessage(message: ["check": "identity"], sender: [:]))?["value"] as? [String: Any])
        XCTAssertEqual(r["hasIdentity"] as? Bool, true)
        XCTAssertEqual(r["hasLaunch"] as? Bool, true)
        XCTAssertEqual(r["hasAuthToken"] as? Bool, true)
        XCTAssertEqual(r["hasOnSignInChanged"] as? Bool, true)
        XCTAssertEqual(r["redirect"] as? String, "https://\(id).chromiumapp.org/cb")
        XCTAssertEqual(r["redirectSlash"] as? String, "https://\(id).chromiumapp.org/cb")
        XCTAssertEqual(r["redirectEmpty"] as? String, "https://\(id).chromiumapp.org/")
    }
}
