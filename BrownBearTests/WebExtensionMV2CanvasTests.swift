//
//  WebExtensionMV2CanvasTests.swift
//  BrownBearTests
//
//  An MV2 background PAGE has a real DOM with <canvas> + Image. Violentmonkey's icon loader
//  (src/background/utils/icon.js `loadIcon`) does `new Image()` → `createElement('canvas')` →
//  `getContext('2d').drawImage(...)` → `toDataURL()` → `getImageData(...)` on EVERY popup/options open,
//  inside the awaited `getIconCache` of its `GetData`/`InitPopup` handlers. Our headless MV2 background
//  returned null from getContext and had no `Image`, so that path THREW — rejecting the handler, dropping
//  the response, and making VM's popup/options destructure `undefined` (the "cannot be destructured" /
//  "InitPopup" errors and the "script disappears on options reload"). This boots an MV2 background and
//  runs VM's exact loadIcon shape, asserting it no longer throws and yields a valid data-URI + ImageData.
//

import XCTest
@testable import BrownBear

final class WebExtensionMV2CanvasTests: XCTestCase {

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
            extensionID: extensionID, extensionName: "Test",
            storage: WebExtensionStorage(suiteName: "brownbear.webext.mv2canvas.\(UUID().uuidString)"),
            logSink: { _ in })
        context.boot(runtimeJS: try backgroundRuntimeSource(),
                     backgroundSource: background,
                     manifestJSON: manifestJSON,
                     baseURL: "chrome-extension://\(extensionID)/",
                     messages: [:])
        return context
    }

    func testMV2CanvasAndImageDoNotThrow() async throws {
        let manifest = #"{"manifest_version":2,"name":"VMCanvas","version":"1.0","background":{"scripts":["bg.js"]}}"#
        let context = try makeContext(manifestJSON: manifest, background: """
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || msg.check !== 'canvas') { return; }
          (async function () {
            var out = { threw: false };
            try {
              // Violentmonkey loadIcon shape (icon.js):
              var img = new Image();
              out.imageIsCtor = (typeof Image === 'function');
              img.src = 'https://example.com/icon_38.png';
              await new Promise(function (res) { img.onload = res; img.onerror = function () { res(); }; });
              var canvas = document.createElement('canvas');
              canvas.width = 38; canvas.height = 38;
              var ctx = canvas.getContext('2d');
              out.ctxOk = !!ctx && typeof ctx.drawImage === 'function';
              ctx.drawImage(img, 0, 0, 38, 38);
              out.dataUrl = canvas.toDataURL();
              var data = ctx.getImageData(0, 0, 38, 38);
              out.imgDataLen = data.data.length;
              out.imgDataTyped = (data.data instanceof Uint8ClampedArray);
              out.measure = ctx.measureText('x').width;
            } catch (e) {
              out.threw = true; out.error = String((e && e.message) || e);
            }
            sendResponse(out);
          })();
          return true;   // async sendResponse
        });
        """)
        defer { context.shutdown() }

        let response = await context.deliverRuntimeMessage(message: ["check": "canvas"], sender: [:])
        let r = try XCTUnwrap(response?["value"] as? [String: Any], "the MV2 background must answer")
        XCTAssertEqual(r["threw"] as? Bool, false, "loadIcon's canvas/Image path must not throw: \(r["error"] ?? "")")
        XCTAssertEqual(r["imageIsCtor"] as? Bool, true, "Image must be a constructor in an MV2 background")
        XCTAssertEqual(r["ctxOk"] as? Bool, true, "getContext('2d') must return a usable 2D context")
        XCTAssertEqual((r["dataUrl"] as? String)?.hasPrefix("data:image/png"), true,
                       "toDataURL returns a valid PNG data-URI")
        XCTAssertEqual(r["imgDataLen"] as? Int, 38 * 38 * 4, "getImageData has w*h*4 bytes")
        XCTAssertEqual(r["imgDataTyped"] as? Bool, true, "getImageData.data is a Uint8ClampedArray")
    }
}
