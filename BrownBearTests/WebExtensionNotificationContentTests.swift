//
//  WebExtensionNotificationContentTests.swift
//  BrownBearTests
//
//  The pure chrome.notifications NotificationOptions → UNMutableNotificationContent mapping behind
//  WebExtensionNotificationManager. These are the table-driven, simulator-free parts of the API: the
//  option→content field mapping, priority/silent → sound, the button → category-identifier derivation,
//  and the composite-id round-trip. (Actual delivery needs UNUserNotificationCenter and is exercised
//  on-device, not here.)
//

import XCTest
import UserNotifications
@testable import BrownBear

@MainActor
final class WebExtensionNotificationContentTests: XCTestCase {

    private let extID = "abcdefghijklmnopabcdefghijklmnop"

    func testTitleMessageContextMap() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "Hello", "message": "World", "contextMessage": "ctx"],
            extensionID: extID)
        XCTAssertEqual(content.title, "Hello")
        XCTAssertEqual(content.body, "World")
        XCTAssertEqual(content.subtitle, "ctx")
    }

    func testMissingFieldsLeaveDefaults() {
        let content = WebExtensionNotificationManager.notificationContent(from: [:], extensionID: extID)
        XCTAssertEqual(content.title, "")
        XCTAssertEqual(content.body, "")
        XCTAssertEqual(content.subtitle, "")
        // No buttons ⇒ no category bound.
        XCTAssertEqual(content.categoryIdentifier, "")
    }

    func testThreadIdentifierIsExtensionScoped() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x"], extensionID: extID)
        XCTAssertEqual(content.threadIdentifier, extID, "notifications group per-extension")
        XCTAssertEqual(content.userInfo["extensionID"] as? String, extID)
    }

    func testDefaultPriorityGetsSound() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x"], extensionID: extID)
        XCTAssertNotNil(content.sound, "priority 0, not silent ⇒ default sound")
    }

    func testNegativePriorityIsSilent() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x", "priority": -1], extensionID: extID)
        XCTAssertNil(content.sound, "low/min priority ⇒ no sound")
    }

    func testSilentSuppressesSound() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x", "priority": 2, "silent": true], extensionID: extID)
        XCTAssertNil(content.sound, "silent:true wins over high priority")
    }

    func testButtonsBindCategoryIdentifier() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x", "buttons": [["title": "Open"], ["title": "Dismiss"]]],
            extensionID: extID)
        let expected = WebExtensionNotificationManager.categoryIdentifier(
            extensionID: extID, titles: ["Open", "Dismiss"])
        XCTAssertEqual(content.categoryIdentifier, expected)
        XCTAssertFalse(content.categoryIdentifier.isEmpty)
    }

    func testButtonsCapAtTwoForChromeParity() {
        let three: [[String: Any]] = [["title": "A"], ["title": "B"], ["title": "C"]]
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x", "buttons": three], extensionID: extID)
        // Only the first two titles participate in the category id.
        let expected = WebExtensionNotificationManager.categoryIdentifier(extensionID: extID, titles: ["A", "B"])
        XCTAssertEqual(content.categoryIdentifier, expected)
    }

    func testCategoryIdentifierIsStableAndDistinctPerTitles() {
        let first = WebExtensionNotificationManager.categoryIdentifier(extensionID: extID, titles: ["X", "Y"])
        let same = WebExtensionNotificationManager.categoryIdentifier(extensionID: extID, titles: ["X", "Y"])
        let other = WebExtensionNotificationManager.categoryIdentifier(extensionID: extID, titles: ["X", "Z"])
        XCTAssertEqual(first, same, "same titles ⇒ same category id (reused, not re-registered)")
        XCTAssertNotEqual(first, other, "different titles ⇒ different category id")
        XCTAssertTrue(first.hasPrefix("bb.notif." + extID))
    }

    func testIconUrlStashedForAttachmentResolution() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x", "iconUrl": "icons/48.png"], extensionID: extID)
        XCTAssertEqual(content.userInfo["iconUrl"] as? String, "icons/48.png")
    }

    func testTypeStashedInUserInfo() {
        let content = WebExtensionNotificationManager.notificationContent(
            from: ["title": "x", "type": "basic"], extensionID: extID)
        XCTAssertEqual(content.userInfo["type"] as? String, "basic")
    }

    func testCompositeIdRoundTripsForDistinctExtensions() {
        let extA = String(repeating: "a", count: 32)
        let extB = String(repeating: "b", count: 32)
        let idA = WebExtensionNotificationManager.compositeID(extensionID: extA, notificationID: "status")
        let idB = WebExtensionNotificationManager.compositeID(extensionID: extB, notificationID: "status")
        XCTAssertNotEqual(idA, idB, "same notification id under two extensions must not collide")
        XCTAssertTrue(idA.hasPrefix(extA), "the composite id is prefixed by its extension id")
    }
}
