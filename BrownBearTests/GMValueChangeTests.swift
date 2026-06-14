//
//  GMValueChangeTests.swift
//  BrownBearTests
//
//  The transport for cross-context GM value sync: a GMValueChangeBroadcast (a value type) must survive
//  being carried as a Notification's `object` and cast back, since that's how a background/@crontab or
//  dashboard write reaches the foreground InjectionOrchestrator to update open pages. The end-to-end
//  page delivery is device-gated (needs a live webView session); this guards the encoding.
//

import XCTest
@testable import BrownBear

final class GMValueChangeTests: XCTestCase {

    func testBroadcastRoundTripsThroughNotificationObject() {
        var received: GMValueChangeBroadcast?
        let token = NotificationCenter.default.addObserver(
            forName: .brownBearGMValueChangedExternally, object: nil, queue: nil) { note in
            received = note.object as? GMValueChangeBroadcast
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let id = UUID()
        NotificationCenter.default.post(
            name: .brownBearGMValueChangedExternally,
            object: GMValueChangeBroadcast(scriptID: id, changes: [
                GMValueChange(key: "count", old: "1", new: "2"),
                GMValueChange(key: "gone", old: "\"x\"", new: nil)
            ]))

        // queue: nil delivers synchronously on post, so `received` is set by now.
        XCTAssertEqual(received?.scriptID, id, "scriptID survives the Any-boxed notification object")
        XCTAssertEqual(received?.changes.count, 2)
        XCTAssertEqual(received?.changes.first?.key, "count")
        XCTAssertEqual(received?.changes.first?.old, "1")
        XCTAssertEqual(received?.changes.first?.new, "2")
        XCTAssertEqual(received?.changes.last?.key, "gone")
        XCTAssertNil(received?.changes.last?.new, "a deletion carries new == nil through the transport")
    }
}
