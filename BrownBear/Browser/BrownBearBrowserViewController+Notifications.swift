//
//  BrownBearBrowserViewController+Notifications.swift
//  BrownBear
//
//  The browser's implementation of the chrome.notifications side of WebExtensionBridgeHost. The
//  actual work lives in the process-wide WebExtensionNotificationManager (which owns
//  UNUserNotificationCenter and the id↔extension attribution); the browser VC just forwards, exactly
//  as it forwards chrome.tabs to TabManager in +WebExtensions. Split into its own file so it never
//  collides with the tabs/scripting host extensions.
//

import UIKit

extension BrownBearBrowserViewController {

    func webExtNotificationsCreate(extensionID: String, notificationID: String?,
                                   options: [String: Any]) async throws -> String {
        try await WebExtensionNotificationManager.shared.create(extensionID: extensionID,
                                                                notificationID: notificationID,
                                                                options: options)
    }

    func webExtNotificationsUpdate(extensionID: String, notificationID: String,
                                   options: [String: Any]) async throws -> Bool {
        try await WebExtensionNotificationManager.shared.update(extensionID: extensionID,
                                                                notificationID: notificationID,
                                                                options: options)
    }

    func webExtNotificationsClear(extensionID: String, notificationID: String) async throws -> Bool {
        try await WebExtensionNotificationManager.shared.clear(extensionID: extensionID,
                                                               notificationID: notificationID)
    }

    func webExtNotificationsGetAll(extensionID: String) async throws -> [String: Bool] {
        try await WebExtensionNotificationManager.shared.getAll(extensionID: extensionID)
    }
}
