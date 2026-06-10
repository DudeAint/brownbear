//
//  WebExtensionNotificationManager.swift
//  BrownBear
//
//  Backs chrome.notifications for browser extensions (Module 6) with iOS local notifications. Each
//  extension that declares the "notifications" permission may create/update/clear banner
//  notifications through UNUserNotificationCenter; taps, dismissals, and action-button taps are
//  routed back to the originating extension's background worker (and any open popup) as
//  chrome.notifications.onClicked / onClosed / onButtonClicked.
//
//  Isolation & identity: a UN notification's identifier is global to the app, but chrome notification
//  ids are per-extension and an extension may reuse another's id ("status", "alert", …). We therefore
//  store every notification under a COMPOSITE identifier "<extensionID>|<notificationID>" so two
//  extensions' same-named notifications never collide, and a tap can be attributed to exactly the
//  extension that created it before any event is dispatched.
//
//  Threading: this class is @MainActor (it owns UIKit-adjacent UN state and posts main-thread
//  notifications). The UNUserNotificationCenterDelegate callbacks are nonisolated, so a small
//  forwarder NSObject receives them off-actor and hops back onto the main actor.
//

import Foundation
import UserNotifications

@MainActor
final class WebExtensionNotificationManager: NSObject {

    /// Process-wide instance. The host (browser VC) and the background installer both reach
    /// notifications through this single manager so id↔extension attribution is consistent.
    static let shared = WebExtensionNotificationManager()

    private let center: UNUserNotificationCenter
    private let store: WebExtensionStore
    private let forwarder = DelegateForwarder()

    /// Composite-id → extension id, so a delegate callback (which only sees the UN identifier) can be
    /// attributed to the extension that owns it. We keep this even after a notification is presented,
    /// since a tap can arrive much later; entries are pruned on clear / dismissal.
    private var owners: [String: String] = [:]

    private var didConfigureDelegate = false

    init(center: UNUserNotificationCenter = .current(),
         store: WebExtensionStore = BrownBearServices.shared.webExtensionStore) {
        self.center = center
        self.store = store
        super.init()
    }

    /// Install the delegate so taps/dismissals route here. Idempotent. Call once at app launch
    /// (AppDelegate) BEFORE any notification can be delivered — otherwise a tap that wakes the app
    /// from a cold start would be dropped because no delegate was set in time.
    func configureDelegate() {
        guard !didConfigureDelegate else { return }
        didConfigureDelegate = true
        forwarder.manager = self
        center.delegate = forwarder
    }

    // MARK: - chrome.notifications surface

    /// chrome.notifications.create. Gated on the extension's "notifications" permission. Returns the
    /// effective notification id (the caller's, or a freshly minted one when none was supplied).
    /// Requests authorization on first use; if the user declined, the notification simply isn't shown
    /// but the id is still returned (Chrome resolves create() regardless of the OS permission state).
    func create(extensionID: String, notificationID: String?, options: [String: Any]) async throws -> String {
        try await requirePermission(extensionID)
        let id: String
        if let supplied = notificationID, !supplied.isEmpty {
            id = supplied
        } else {
            id = "bb-notif-" + UUID().uuidString
        }
        let composite = Self.compositeID(extensionID: extensionID, notificationID: id)

        let granted = await ensureAuthorization()
        owners[composite] = extensionID
        guard granted else { return id }   // mirror Chrome: id resolved even when the OS suppresses it.

        await registerCategory(for: options, extensionID: extensionID)
        let content = Self.notificationContent(from: options, extensionID: extensionID)
        await deliver(content.resolvingAttachment(store: store), composite: composite)
        return id
    }

    /// chrome.notifications.update. Returns true if a notification with that id existed. iOS has no
    /// in-place update, so we re-deliver under the same identifier (UN replaces it). Chrome's update
    /// is a partial merge of the original options; without retaining those we deliver the supplied
    /// fields as a full replacement (documented limit).
    func update(extensionID: String, notificationID: String, options: [String: Any]) async throws -> Bool {
        try await requirePermission(extensionID)
        let composite = Self.compositeID(extensionID: extensionID, notificationID: notificationID)
        let pending = await isPending(composite)
        let delivered = isDelivered(await deliveredIdentifiers(), composite)
        let existed = owners[composite] != nil || pending || delivered
        guard existed else { return false }

        let granted = await ensureAuthorization()
        owners[composite] = extensionID
        guard granted else { return true }

        await registerCategory(for: options, extensionID: extensionID)
        let content = Self.notificationContent(from: options, extensionID: extensionID)
        await deliver(content.resolvingAttachment(store: store), composite: composite)
        return true
    }

    /// chrome.notifications.clear. Removes the (pending or delivered) notification; returns whether it
    /// was present. Drops the owner mapping so a stale tap can't be attributed after clearing.
    func clear(extensionID: String, notificationID: String) async throws -> Bool {
        try await requirePermission(extensionID)
        let composite = Self.compositeID(extensionID: extensionID, notificationID: notificationID)
        let wasPending = await isPending(composite)
        let wasDelivered = isDelivered(await deliveredIdentifiers(), composite)
        let known = owners[composite] != nil
        center.removePendingNotificationRequests(withIdentifiers: [composite])
        center.removeDeliveredNotifications(withIdentifiers: [composite])
        owners.removeValue(forKey: composite)
        return wasPending || wasDelivered || known
    }

    /// chrome.notifications.getAll. Returns the extension's currently-live notification ids as an
    /// object { id: true } (Chrome's shape). Only this extension's notifications are visible.
    func getAll(extensionID: String) async throws -> [String: Bool] {
        try await requirePermission(extensionID)
        let prefix = extensionID + Self.separator
        var ids = Set<String>()
        for composite in await deliveredIdentifiers() where composite.hasPrefix(prefix) {
            ids.insert(String(composite.dropFirst(prefix.count)))
        }
        for request in await center.pendingNotificationRequests() where request.identifier.hasPrefix(prefix) {
            ids.insert(String(request.identifier.dropFirst(prefix.count)))
        }
        // Owners we minted this session but that the OS may have already dismissed are intentionally
        // NOT included — getAll reflects what's live, matching Chrome.
        var out: [String: Bool] = [:]
        for id in ids { out[id] = true }
        return out
    }

    // MARK: - Inbound delegate events (hopped to the main actor by the forwarder)

    /// A delivered banner was tapped (default action) → onClicked.
    fileprivate func handleTap(composite: String) {
        guard let (extensionID, notificationID) = split(composite) else { return }
        postEvent(kind: "clicked", extensionID: extensionID, notificationID: notificationID)
    }

    /// The user explicitly dismissed the banner → onClosed(byUser: true).
    fileprivate func handleDismiss(composite: String) {
        guard let (extensionID, notificationID) = split(composite) else { return }
        owners.removeValue(forKey: composite)
        postEvent(kind: "closed", extensionID: extensionID, notificationID: notificationID,
                  extra: ["byUser": true])
    }

    /// An action button was tapped → onButtonClicked(notificationID, buttonIndex).
    fileprivate func handleButton(composite: String, buttonIndex: Int) {
        guard let (extensionID, notificationID) = split(composite) else { return }
        postEvent(kind: "buttonClicked", extensionID: extensionID, notificationID: notificationID,
                  extra: ["buttonIndex": buttonIndex])
    }

    // MARK: - Event fan-out

    /// Post a notification-event onto the shared bus. WebExtensionRuntime (→ background worker) and
    /// any open WebExtensionPageViewController (→ popup) observe it and dispatch into JS. Mirrors the
    /// storage.onChanged fan-out so notifications reach every live context of the extension.
    private func postEvent(kind: String, extensionID: String, notificationID: String,
                           extra: [String: Any] = [:]) {
        var info: [String: Any] = ["extensionID": extensionID, "kind": kind, "notificationID": notificationID]
        for (key, value) in extra { info[key] = value }
        NotificationCenter.default.post(name: .brownBearExtensionNotificationEvent, object: nil, userInfo: info)
    }

    // MARK: - Permission gate

    /// Throw unless the extension declared the "notifications" API permission. Chrome silently no-ops
    /// undeclared notification calls; we fail closed so a script can't surface banners it never asked
    /// the user to allow at install time.
    private func requirePermission(_ extensionID: String) async throws {
        guard let ext = await store.ext(for: extensionID), ext.enabled,
              let manifest = ext.manifest,
              manifest.permissions.contains("notifications") else {
            throw BrownBearError.bridgeRejected("the \"notifications\" permission is not granted")
        }
    }

    // MARK: - UN authorization

    /// Request (once) and return whether alerts/sounds are authorized. Provisional is treated as
    /// granted (the banner shows quietly), matching how Chrome's notifications still surface.
    private func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    // MARK: - Delivery

    private func deliver(_ content: UNMutableNotificationContent, composite: String) async {
        // Immediate (1s) trigger — chrome.notifications fire now; a nil trigger is also immediate but
        // a 1s interval keeps the request valid across all iOS versions without UI flake.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: composite, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            // Best-effort: a malformed content (e.g. bad attachment) shouldn't crash the bridge.
        }
    }

    /// Register a UNNotificationCategory carrying the action buttons declared in `options.buttons`, so
    /// the delivered notification shows them. Categories are merged into the existing set (never
    /// clobbering another extension's). No-op when the options declare no buttons.
    private func registerCategory(for options: [String: Any], extensionID: String) async {
        guard let buttons = options["buttons"] as? [[String: Any]], !buttons.isEmpty else { return }
        let titles = buttons.prefix(2).compactMap { $0["title"] as? String }
        guard !titles.isEmpty else { return }
        let identifier = Self.categoryIdentifier(extensionID: extensionID, titles: titles)
        var actions: [UNNotificationAction] = []
        for (index, title) in titles.enumerated() {
            actions.append(UNNotificationAction(identifier: "bb.btn.\(index)", title: title, options: []))
        }
        let category = UNNotificationCategory(identifier: identifier, actions: actions,
                                              intentIdentifiers: [], options: [])
        var existing = await center.notificationCategories()
        existing.insert(category)
        center.setNotificationCategories(existing)
    }

    // MARK: - Live-state queries

    private func isPending(_ composite: String) async -> Bool {
        await center.pendingNotificationRequests().contains { $0.identifier == composite }
    }

    private func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    private nonisolated func isDelivered(_ identifiers: [String], _ composite: String) -> Bool {
        identifiers.contains(composite)
    }

    // MARK: - Composite id helpers

    /// Separator chosen so it can't appear inside a Chrome extension id (a–p only) nor be a common
    /// notification-id character, keeping the split unambiguous.
    fileprivate static let separator = "\u{1F}|\u{1F}"

    static func compositeID(extensionID: String, notificationID: String) -> String {
        extensionID + separator + notificationID
    }

    private func split(_ composite: String) -> (extensionID: String, notificationID: String)? {
        guard let range = composite.range(of: Self.separator) else { return nil }
        let extensionID = String(composite[composite.startIndex..<range.lowerBound])
        let notificationID = String(composite[range.upperBound...])
        guard !extensionID.isEmpty else { return nil }
        return (extensionID, notificationID)
    }

    // MARK: - Pure option → content mapping

    /// Map a chrome.notifications NotificationOptions object to a UNMutableNotificationContent. Pure
    /// and side-effect free (the icon attachment is resolved separately, async, since it touches the
    /// store; the button category is registered separately too), so it can be unit-tested in
    /// isolation. Supported chrome fields: title, message, contextMessage, priority, silent,
    /// buttons[].title, iconUrl (local-file only). Unsupported on iOS: type (image/list/progress),
    /// progress, eventTime, imageUrl, requireInteraction — documented limits.
    static func notificationContent(from options: [String: Any],
                                    extensionID: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let title = options["title"] as? String { content.title = title }
        if let message = options["message"] as? String { content.body = message }
        if let contextMessage = options["contextMessage"] as? String, !contextMessage.isEmpty {
            content.subtitle = contextMessage
        }
        // priority: chrome -2…2. Map ≤ -1 (low/min) to no sound; ≥ 0 to default sound, unless silent.
        let priority = (options["priority"] as? Int) ?? 0
        let silent = (options["silent"] as? Bool) ?? false
        content.sound = (silent || priority < 0) ? nil : .default

        // Per-extension thread so an extension's notifications group together and never interleave
        // into another extension's thread in Notification Center.
        content.threadIdentifier = extensionID
        if let buttons = options["buttons"] as? [[String: Any]], !buttons.isEmpty {
            let titles = buttons.prefix(2).compactMap { $0["title"] as? String }
            if !titles.isEmpty {
                content.categoryIdentifier = Self.categoryIdentifier(extensionID: extensionID, titles: titles)
            }
        }
        // Stash chrome's notification type so the delegate / tests can read it back if needed.
        if let type = options["type"] as? String { content.userInfo["type"] = type }
        // Stash iconUrl so `resolvingAttachment` can turn an in-package icon into a UN attachment.
        if let iconURL = options["iconUrl"] as? String { content.userInfo["iconUrl"] = iconURL }
        content.userInfo["extensionID"] = extensionID
        return content
    }

    /// The stable category identifier for an extension's set of button titles. Keyed by extension +
    /// titles so identical button sets reuse one category rather than registering without bound. chrome
    /// allows ≤ 2 buttons; iOS supports more, but we cap at chrome's 2 for parity. Pure.
    static func categoryIdentifier(extensionID: String, titles: [String]) -> String {
        "bb.notif." + extensionID + "." + titles.prefix(2).joined(separator: "\u{1F}")
    }
}

private extension UNMutableNotificationContent {
    /// Attach the notification's iconUrl as a local-file image attachment when it resolves to a file
    /// PACKAGED INSIDE the extension (chrome-extension:// path or a bare relative path). Remote URLs
    /// and data: URLs are ignored — iOS attachments must be local files, and we won't fetch arbitrary
    /// hosts from a notification (a silent SSRF/exfil vector). Returns self for chaining.
    func resolvingAttachment(store: WebExtensionStore) async -> UNMutableNotificationContent {
        guard let extensionID = userInfo["extensionID"] as? String else { return self }
        // The mapping stashes the raw iconUrl under "iconUrl" only when present; read it back.
        guard let iconURL = userInfo["iconUrl"] as? String, !iconURL.isEmpty else { return self }
        var path = iconURL
        // Strip the extension's own resource prefix (chrome- or moz-extension for a Firefox build).
        for scheme in WebExtensionSchemeHandler.extensionSchemes {
            let prefix = "\(scheme)://\(extensionID)/"
            if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)); break }
        }
        // Reject absolute/remote/data URLs: only an in-package relative path is honored.
        guard !path.contains("://"), !path.hasPrefix("data:") else { return self }
        guard let data = await store.file(extensionID: extensionID, path: path) else { return self }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-notif-\(UUID().uuidString)")
            .appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: temp, options: .atomic)
            let attachment = try UNNotificationAttachment(identifier: "icon", url: temp, options: nil)
            attachments = [attachment]
        } catch {
            // Best-effort: a bad icon must not block the banner.
        }
        return self
    }
}

/// Nonisolated UNUserNotificationCenterDelegate forwarder. UN delegate methods are called on an
/// arbitrary thread; this hops every event onto the main actor where the manager lives. Kept separate
/// from the manager so the manager can stay fully @MainActor.
private final class DelegateForwarder: NSObject, UNUserNotificationCenterDelegate {

    weak var manager: WebExtensionNotificationManager?

    /// Show the banner even while the app is foregrounded — extensions expect their notification to be
    /// visible regardless of app state (Chrome shows it in any case).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// A tap, dismissal, or action-button tap on one of our notifications.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let composite = response.notification.request.identifier
        let actionID = response.actionIdentifier
        Task { @MainActor [weak manager] in
            // This forwarder owns the single UN delegate (claimed unconditionally at launch), so it also
            // routes USERSCRIPT GM_notification taps — UN allows only one center delegate (see
            // UserScriptNotificationManager's delegate-collision note). Userscript ids are namespaced, so
            // ownership is unambiguous. The ownership check + dispatch run here, on the main actor, since
            // UserScriptNotificationManager is @MainActor-isolated.
            if UserScriptNotificationManager.owns(compositeID: composite) {
                UserScriptNotificationManager.shared.routeResponse(composite: composite, actionID: actionID)
                completionHandler()
                return
            }
            guard let manager else { completionHandler(); return }
            switch actionID {
            case UNNotificationDefaultActionIdentifier:
                manager.handleTap(composite: composite)
            case UNNotificationDismissActionIdentifier:
                manager.handleDismiss(composite: composite)
            default:
                if actionID.hasPrefix("bb.btn."), let index = Int(actionID.dropFirst("bb.btn.".count)) {
                    manager.handleButton(composite: composite, buttonIndex: index)
                }
            }
            completionHandler()
        }
    }
}
