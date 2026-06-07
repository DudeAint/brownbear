//
//  WebExtensionEventEmitterTests.swift
//  BrownBearTests
//
//  Verifies the browser-event PUSH path: WebExtensionEventEmitter builds chrome-shaped event args
//  and routes them through WebExtensionRuntime.dispatchEventToAll with the right name, permission
//  gate, and onUpdated diffing. We exercise the emitter against a spy runtime so the assertions are
//  pure logic (no JSContext, no WKWebView), per CLAUDE.md §6.
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionEventEmitterTests: XCTestCase {

    /// Captures every fan-out so we can assert name / args / permission without booting a worker.
    private final class SpyRuntime: WebExtensionRuntime {
        struct Fired { let name: String; let argsJSON: String; let permission: String? }
        var fired: [Fired] = []
        override func dispatchEventToAll(name: String, argsJSON: String, requiredPermission: String?) {
            fired.append(Fired(name: name, argsJSON: argsJSON, permission: requiredPermission))
        }
    }

    private func makeEmitter() -> (WebExtensionEventEmitter, SpyRuntime) {
        let runtime = SpyRuntime()
        let emitter = WebExtensionEventEmitter(runtime: runtime,
                                               registry: WebExtensionTabRegistry(),
                                               host: nil)
        return (emitter, runtime)
    }

    private func decodeArgs(_ json: String) -> [Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] ?? []
    }

    func testTabCreatedFiresOnCreatedWithTabRecord() {
        let (emitter, runtime) = makeEmitter()
        emitter.tabCreated(["id": 7, "url": "https://example.com", "status": "loading"])
        XCTAssertEqual(runtime.fired.count, 1)
        XCTAssertEqual(runtime.fired[0].name, "tabs.onCreated")
        XCTAssertNil(runtime.fired[0].permission, "tabs events need no permission")
        let args = decodeArgs(runtime.fired[0].argsJSON)
        XCTAssertEqual((args.first as? [String: Any])?["id"] as? Int, 7)
    }

    func testTabActivatedShape() {
        let (emitter, runtime) = makeEmitter()
        emitter.tabActivated(extTabId: 3)
        let args = decodeArgs(runtime.fired[0].argsJSON)
        let info = args.first as? [String: Any]
        XCTAssertEqual(runtime.fired[0].name, "tabs.onActivated")
        XCTAssertEqual(info?["tabId"] as? Int, 3)
        XCTAssertEqual(info?["windowId"] as? Int, 1)
    }

    func testTabRemovedShape() {
        let (emitter, runtime) = makeEmitter()
        emitter.tabRemoved(extTabId: 9, isWindowClosing: true)
        let args = decodeArgs(runtime.fired[0].argsJSON)
        XCTAssertEqual(args.first as? Int, 9)
        XCTAssertEqual((args.last as? [String: Any])?["isWindowClosing"] as? Bool, true)
    }

    func testTabUpdatedEmitsOnlyChangedDelta() {
        let (emitter, runtime) = makeEmitter()
        // Establish a baseline via onCreated (also seeds lastRecords).
        emitter.tabCreated(["id": 1, "status": "loading", "url": "https://a.test", "title": "A"])
        // Only status changes → changeInfo should be exactly {status: complete}.
        emitter.tabUpdated(["id": 1, "status": "complete", "url": "https://a.test", "title": "A"])
        let updates = runtime.fired.filter { $0.name == "tabs.onUpdated" }
        XCTAssertEqual(updates.count, 1)
        let args = decodeArgs(updates[0].argsJSON)
        XCTAssertEqual(args[0] as? Int, 1)
        let changeInfo = args[1] as? [String: Any]
        XCTAssertEqual(changeInfo?.count, 1)
        XCTAssertEqual(changeInfo?["status"] as? String, "complete")
    }

    func testTabUpdatedSuppressedWhenNothingTrackedChanged() {
        let (emitter, runtime) = makeEmitter()
        emitter.tabCreated(["id": 2, "status": "complete", "url": "https://b.test"])
        emitter.tabUpdated(["id": 2, "status": "complete", "url": "https://b.test"])
        XCTAssertTrue(runtime.fired.filter { $0.name == "tabs.onUpdated" }.isEmpty,
                      "no tracked property changed → onUpdated must not fire")
    }

    func testWebNavigationEventsRequirePermissionAndCarryMainFrameIds() {
        let (emitter, runtime) = makeEmitter()
        emitter.webNavCommitted(extTabId: 5, url: "https://example.com/page")
        XCTAssertEqual(runtime.fired[0].name, "webNavigation.onCommitted")
        XCTAssertEqual(runtime.fired[0].permission, "webNavigation")
        let details = decodeArgs(runtime.fired[0].argsJSON).first as? [String: Any]
        XCTAssertEqual(details?["tabId"] as? Int, 5)
        XCTAssertEqual(details?["frameId"] as? Int, 0, "iOS exposes only the main frame")
        XCTAssertEqual(details?["parentFrameId"] as? Int, -1)
        XCTAssertEqual(details?["url"] as? String, "https://example.com/page")
    }

    func testErrorOccurredCarriesError() {
        let (emitter, runtime) = makeEmitter()
        emitter.webNavErrorOccurred(extTabId: 4, url: "https://x.test", error: "net::ERR_FAILED")
        let details = decodeArgs(runtime.fired[0].argsJSON).first as? [String: Any]
        XCTAssertEqual(runtime.fired[0].name, "webNavigation.onErrorOccurred")
        XCTAssertEqual(details?["error"] as? String, "net::ERR_FAILED")
    }
}
