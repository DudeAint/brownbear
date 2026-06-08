//
//  WebExtensionMV2BackgroundTests.swift
//  BrownBearTests
//
//  Regression coverage for the Violentmonkey (Manifest V2) background crash:
//  "undefined is not an object (evaluating 'a[ge]=…')". VM ships its background as `background.scripts`
//  (an MV2 background PAGE bundle), which we concatenate and evaluate in the headless JSContext. Its
//  webpack banner (safe-globals.js) reads the WebExtensions API SYNCHRONOUSLY at module-evaluation time,
//  and the bundle ends with `window._bg = 1`. Two gaps aborted init:
//    1. chrome.webRequest lacked the addListener option enums, so a top-level
//       `webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS` read threw on `undefined.EXTRA_HEADERS`.
//    2. `window` was undefined (MV3 service workers have none), so the trailing `window._bg = 1` threw.
//  When an early module throws, a later module-namespace object is left undefined and the deferred
//  `a[ge]=…` access crashes — the reported symptom. The MV3 test guards the inverse: a service worker
//  must NOT get a `window` (libraries feature-detect `typeof window` to tell a worker from a page).
//

import XCTest
@testable import BrownBear

final class WebExtensionMV2BackgroundTests: XCTestCase {

    struct RuntimeNotBundled: Error {}

    private func backgroundRuntimeSource() throws -> String {
        let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js")
            ?? Bundle(for: Self.self).url(forResource: "brownbear-webext-background", withExtension: "js")
        guard let url else { throw RuntimeNotBundled() }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeContext(manifestJSON: String, background: String) throws -> WebExtensionBackgroundContext {
        let extensionID = "abcdefghijklmnopabcdefghijklmnop"
        let context = WebExtensionBackgroundContext(
            extensionID: extensionID,
            extensionName: "Test",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.mv2.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: manifestJSON,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    /// An MV2 background that replicates Violentmonkey's top-level init reads (safe-globals.js +
    /// requests-core.js + the trailing `window._bg = 1`). All of this runs at GLOBAL scope BEFORE the
    /// onMessage listener registers — so if any access throws, no listener registers and the dispatch
    /// returns the no-listener marker. A successful response proves the whole init survived.
    func testViolentmonkeyStyleMV2BackgroundInitializes() async throws {
        let manifest = #"""
        {"manifest_version":2,"name":"VMTest","version":"1.0",
         "options_ui":{"page":"options/index.html"},
         "icons":{"16":"icon16.png","48":"icon48.png"},
         "background":{"scripts":["bg.js"]}}
        """#
        let context = try makeContext(manifestJSON: manifest, background: """
        // --- safe-globals.js banner (runs first, at global scope) ---
        var IS_FIREFOX = 'contextualIdentities' in chrome || 'activityLog' in chrome;
        var extensionRoot = chrome.runtime.getURL('/');
        var m = chrome.runtime.getManifest();
        var optionsPage = chrome.runtime.getURL(m.options_ui.page).split('#', 1)[0];
        var ICON_PREFIX = chrome.runtime.getURL(m.icons['16'].replace('16.png', ''));
        // --- requests-core.js / preinject.js top-level webRequest enum reads ---
        var EXTRA = [chrome.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS].filter(Boolean);
        var EXTRA_RX = chrome.webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS;
        // --- notifications.js top-level listener registration ---
        chrome.notifications.onClicked.addListener(function () {});
        chrome.notifications.onClosed.addListener(function () {});
        // --- ua.js top-level navigator read ---
        var uaOk = typeof navigator.userAgent === 'string' && navigator.userAgent.length > 0;
        // --- background/index.js trailing line ---
        window._bg = 1;
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'vminit') { return; }
          sendResponse({
            isFirefox: IS_FIREFOX,
            rootEndsSlash: extensionRoot.charAt(extensionRoot.length - 1) === '/',
            optionsPage: optionsPage,
            iconPrefix: ICON_PREFIX,
            manifestName: m.name,
            extra: EXTRA.join(','), extraRx: EXTRA_RX,
            uaOk: uaOk,
            windowIsGlobal: window === globalThis,
            bg: window._bg
          });
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "vminit"], sender: [:])
        XCTAssertNotEqual(response?["__bbNoListener"] as? Bool, true,
                          "the VM-style background must finish init and register its listener (it aborted before)")
        let r = try XCTUnwrap(response?["value"] as? [String: Any],
                              "the VM-style MV2 background must register its onMessage listener")
        XCTAssertEqual(r["isFirefox"] as? Bool, false, "`'x' in chrome` must not throw (chrome is an object)")
        XCTAssertEqual(r["rootEndsSlash"] as? Bool, true, "getURL('/') must return a slash-terminated root")
        XCTAssertEqual(r["optionsPage"] as? String, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options/index.html")
        XCTAssertEqual(r["iconPrefix"] as? String, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/icon")
        XCTAssertEqual(r["manifestName"] as? String, "VMTest", "getManifest() must return the full nested manifest")
        XCTAssertEqual(r["extra"] as? String, "extraHeaders", "webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS must exist")
        XCTAssertEqual(r["extraRx"] as? String, "extraHeaders", "webRequest.OnHeadersReceivedOptions.EXTRA_HEADERS must exist")
        XCTAssertEqual(r["uaOk"] as? Bool, true)
        XCTAssertEqual(r["windowIsGlobal"] as? Bool, true, "MV2 background: window === the global")
        XCTAssertEqual(r["bg"] as? Int, 1, "`window._bg = 1` must not throw")
    }

    /// An MV3 service worker must NOT expose `window` (Chrome SWs have none; bundles feature-detect it),
    /// but the webRequest option enums — which Chrome exposes everywhere — must still be present.
    func testMV3ServiceWorkerHasNoWindowButHasWebRequestEnums() async throws {
        let manifest = #"{"manifest_version":3,"name":"MV3","version":"1.0","background":{"service_worker":"sw.js"}}"#
        let context = try makeContext(manifestJSON: manifest, background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'mv3' ) { return; }
          sendResponse({
            hasWindow: typeof window !== 'undefined',
            hasExtraHeaders: !!(chrome.webRequest.OnBeforeSendHeadersOptions
                                && chrome.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS === 'extraHeaders')
          });
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "mv3"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any])
        XCTAssertEqual(r["hasWindow"] as? Bool, false, "an MV3 service worker must not have a `window` global")
        XCTAssertEqual(r["hasExtraHeaders"] as? Bool, true, "webRequest option enums exist in MV3 too")
    }
}
