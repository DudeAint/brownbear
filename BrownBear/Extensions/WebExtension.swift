//
//  WebExtension.swift
//  BrownBear
//
//  A stored browser extension: a generated id, the raw manifest, install state, and (on disk) its
//  unpacked files. The parsed manifest is derived on demand so the record stays simply Codable.
//

import Foundation

extension Notification.Name {
    /// Posted (on the main thread) whenever the installed-extension set changes — install, enable/
    /// disable, or uninstall. The foreground engine recompiles content blockers and reloads
    /// background service workers in response, so a change takes effect without an app relaunch.
    static let brownBearExtensionsDidChange = Notification.Name("brownBearExtensionsDidChange")

    /// Posted whenever an extension's `chrome.storage` area changes (from any source: a content
    /// script, the background worker, or uninstall cleanup). Drives `chrome.storage.onChanged`.
    /// userInfo: `extensionID: String`, `area: String`, `changes: [String: [String: String]]`
    /// where each change is `["oldValue": json]` / `["newValue": json]` (omitted key = absent).
    static let brownBearExtensionStorageDidChange = Notification.Name("brownBearExtensionStorageDidChange")

    /// Posted (main thread) when a chrome.notifications event (clicked/closed/buttonClicked) occurs.
    /// userInfo: `extensionID: String`, `kind: String` ("clicked"|"closed"|"buttonClicked"),
    /// `notificationID: String`, and either `byUser: Bool` (closed) or `buttonIndex: Int` (buttonClicked).
    static let brownBearExtensionNotificationEvent = Notification.Name("brownBearExtensionNotificationEvent")

    /// Posted when an extension's runtime-granted optional permissions change (chrome.permissions.request
    /// grant or chrome.permissions.remove). Drives `chrome.permissions.onAdded` / `onRemoved` in the
    /// extension's worker AND its open pages. userInfo: `extensionID: String`, `added: [String: Any]`,
    /// `removed: [String: Any]`, each a `{ permissions: [String], origins: [String] }` delta (either may
    /// be empty). A purely-empty change is not posted.
    static let brownBearExtensionPermissionsDidChange = Notification.Name("brownBearExtensionPermissionsDidChange")
}

struct WebExtension: Codable, Identifiable, Equatable {

    /// A Chrome-style 32-character extension id (lowercase a–p). Generated locally — it is NOT the
    /// Chrome Web Store id (which derives from the developer key), so use `storeID` to match a record
    /// back to a store page.
    let id: String
    /// The verbatim manifest.json, re-parsed on demand.
    var manifestJSON: String
    var enabled: Bool
    var installedAt: Date
    /// The Chrome Web Store id this was installed from (when installed via the store path), so the
    /// in-page store button can tell "already added" and offer Remove. `nil` for sideloaded archives.
    var storeID: String?

    init(id: String, manifestJSON: String, enabled: Bool = true,
         installedAt: Date = Date(), storeID: String? = nil) {
        self.id = id
        self.manifestJSON = manifestJSON
        self.enabled = enabled
        self.installedAt = installedAt
        self.storeID = storeID
    }

    /// The parsed manifest (nil if the stored JSON somehow became invalid).
    var manifest: WebExtensionManifest? {
        guard let data = manifestJSON.data(using: .utf8) else { return nil }
        return try? WebExtensionManifest.parse(data)
    }

    /// The user-facing name, with any Chrome i18n `__MSG_*__` placeholders resolved against the
    /// extension's default-locale messages (a localized extension stores e.g. `__MSG_appName__` here).
    var displayName: String {
        let raw = manifest?.name ?? id
        return WebExtensionLocalizer.resolve(raw, extensionID: id, defaultLocale: manifest?.defaultLocale)
    }

    /// The user-facing description with `__MSG_*__` placeholders resolved, or nil when none is declared.
    var displayDescription: String? {
        guard let raw = manifest?.descriptionText, !raw.isEmpty else { return nil }
        return WebExtensionLocalizer.resolve(raw, extensionID: id, defaultLocale: manifest?.defaultLocale)
    }

    var version: String { manifest?.version ?? "—" }

    /// A chrome-extension-style base URL for this extension's resources.
    var baseURLString: String { "chrome-extension://\(id)/" }

    /// Generate a random Chrome-style id (32 chars from a–p, mapping each hex nibble).
    static func generateID() -> String {
        let alphabet = Array("abcdefghijklmnop")
        var result = ""
        for _ in 0..<32 {
            result.append(alphabet[Int.random(in: 0..<16)])
        }
        return result
    }
}
