//
//  UserScriptNotificationManager.swift
//  BrownBear
//
//  Backs GM_notification for USERSCRIPTS (not browser extensions) with iOS local notifications.
//  WebExtensionNotificationManager already does this for chrome.notifications, but its permission
//  gate (`requirePermission`) hard-fails unless a real *extension* record declares the
//  "notifications" permission — a userscript has no such record, so reusing it directly would always
//  fail closed. Rather than weaken that extension gate (CLAUDE.md §5), we re-implement the same
//  faithful UN pattern here against the userscript identity model: notifications are keyed by a
//  synthetic per-script namespace "us-notif|<scriptUUID>" so two scripts' same-named notifications
//  never collide, and a tap is attributed to exactly the script that created it before any onclick
//  fires.
//
//  Threading: @MainActor (owns UN state + posts main-thread callbacks). The UN delegate callbacks are
//  nonisolated, so a small forwarder NSObject receives them off-actor and hops back onto the actor.
//
//  Security: a script can only ever address its own notifications (the namespace is native-bound to
//  the resolved ScriptSession, never script-supplied). onclick is delivered back into the SAME
//  isolated content world the script runs in, never the page world.
//

import Foundation
import UserNotifications
import WebKit

/// What the router hands the manager so a tap can be routed back to the originating injection's
/// content world. `webView`/`frameInfo` are weak/optional because the tab may be gone by tap time.
@MainActor
struct UserScriptNotificationTarget {
    let scriptID: UUID
    let scriptName: String
    weak var webView: WKWebView?
    var frameInfo: WKFrameInfo?
    let contentWorld: WKContentWorld
    /// Set when the creating script runs in the PAGE world (granted, VM-parity). A click/close then streams
    /// back via window.__bbPageXHR(streamID, "click"|"close") into WKContentWorld.page (the vault's minted-id
    /// channel) — never the isolated __brownbear.dispatchNotification broadcast. nil = isolated world.
    var pageWorldStreamID: String?
}

@MainActor
final class UserScriptNotificationManager: NSObject {

    /// Process-wide instance so id↔script attribution survives across navigations and taps that
    /// arrive long after the banner was posted.
    static let shared = UserScriptNotificationManager()

    private let center: UNUserNotificationCenter
    private let forwarder = DelegateForwarder()

    /// composite id -> the target to deliver onclick/onclose into. Pruned on clear/dismiss.
    private var targets: [String: UserScriptNotificationTarget] = [:]
    /// composite ids whose script registered an onclick/ondone/onclose, so we only round-trip a tap
    /// when the script actually wants it.
    private var wantsClick: Set<String> = []

    private var didConfigureDelegate = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    /// Install the UN delegate so taps route here. Idempotent. iOS allows ONLY ONE delegate; if the
    /// extension notification manager already claimed it, we DON'T clobber it (see the integration
    /// notes for the shared-dispatcher option). Standalone, we own it.
    func configureDelegate() {
        guard !didConfigureDelegate else { return }
        didConfigureDelegate = true
        forwarder.manager = self
        if center.delegate == nil { center.delegate = forwarder }
    }

    // MARK: - GM_notification surface

    /// Create (or replace) a notification for a script. Returns the effective notification id and
    /// whether the OS actually showed it. `notificationID` may be nil (mint one). `wantClick` records
    /// whether the script registered a callback. Requests UN authorization on first use; if denied,
    /// the id is still returned (so the script's logic proceeds) and `shown` is false so the caller
    /// can fall back to an in-app banner.
    @discardableResult
    func create(target: UserScriptNotificationTarget,
                notificationID: String?,
                options: [String: Any],
                wantClick: Bool) async -> (id: String, shown: Bool) {
        let id: String
        if let supplied = notificationID, !supplied.isEmpty { id = supplied }
        else { id = "gm-notif-" + UUID().uuidString }
        let composite = Self.compositeID(scriptID: target.scriptID, notificationID: id)

        let granted = await ensureAuthorization()
        targets[composite] = target
        if wantClick { wantsClick.insert(composite) } else { wantsClick.remove(composite) }
        guard granted else { return (id, false) }

        let content = Self.notificationContent(from: options, fallbackTitle: target.scriptName)
        await deliver(content, composite: composite)
        return (id, true)
    }

    /// Remove a script's notification (GM_notification(...).remove()). Drops the target so a stale tap
    /// can't fire onclick after removal. Returns whether it was known.
    @discardableResult
    func clear(scriptID: UUID, notificationID: String) -> Bool {
        let composite = Self.compositeID(scriptID: scriptID, notificationID: notificationID)
        let known = targets[composite] != nil
        center.removePendingNotificationRequests(withIdentifiers: [composite])
        center.removeDeliveredNotifications(withIdentifiers: [composite])
        targets.removeValue(forKey: composite)
        wantsClick.remove(composite)
        return known
    }

    // MARK: - Inbound delegate events (hopped to the main actor by the forwarder)

    fileprivate func handleTap(composite: String) {
        guard let target = targets[composite], wantsClick.contains(composite) else { return }
        dispatchEvent("click", composite: composite, target: target)
    }

    fileprivate func handleDismiss(composite: String) {
        guard let target = targets[composite] else { return }
        if wantsClick.contains(composite) { dispatchEvent("close", composite: composite, target: target) }
        targets.removeValue(forKey: composite)
        wantsClick.remove(composite)
    }

    /// Whether this composite id belongs to a userscript notification (so a shared UN delegate can
    /// route it here rather than to the extension manager).
    static func owns(compositeID: String) -> Bool { compositeID.hasPrefix(scheme) }

    /// Public entry for a shared UN delegate to forward a response to us (used when the extension
    /// manager owns `center.delegate`). `actionID` is UNNotificationResponse.actionIdentifier.
    func routeResponse(composite: String, actionID: String) {
        switch actionID {
        case UNNotificationDefaultActionIdentifier: handleTap(composite: composite)
        case UNNotificationDismissActionIdentifier: handleDismiss(composite: composite)
        default: break
        }
    }

    // MARK: - Event delivery into the script's isolated world

    private func dispatchEvent(_ kind: String, composite: String, target: UserScriptNotificationTarget) {
        guard let (_, notificationID) = split(composite), let webView = target.webView else { return }
        // A page-world creator gets the click/close streamed into .page via the vault's minted-id channel
        // (window.__bbPageXHR), routed to the handler registered under this streamID — never the isolated
        // __brownbear.dispatchNotification broadcast. target.contentWorld is already .page for that case.
        let js: String
        if let streamID = target.pageWorldStreamID {
            let idLit = ScriptMessageRouter.escapeForJSStringLiteral(streamID)
            let kindLit = ScriptMessageRouter.escapeForJSStringLiteral(kind)
            js = "window.__bbPageXHR&&window.__bbPageXHR('\(idLit)','\(kindLit)',{});"
        } else {
            let payload: [String: Any] = ["id": notificationID, "kind": kind]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let escaped = ScriptMessageRouter.escapeForJSStringLiteral(json)
            js = "window.__brownbear&&window.__brownbear.dispatchNotification&&window.__brownbear.dispatchNotification('\(escaped)');"
        }
        BBEvaluateJavaScriptInFrame(webView, js, target.frameInfo, target.contentWorld)
    }

    // MARK: - UN authorization

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
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: composite, content: content, trigger: trigger)
        do { try await center.add(request) } catch { /* best-effort: a bad content must not crash the bridge */ }
    }

    // MARK: - Composite id helpers

    /// Scheme prefix that brands a composite id as a USERSCRIPT notification, so a shared UN delegate
    /// can tell our ids apart from the extension manager's.
    fileprivate static let scheme = "us-notif\u{1F}"
    private static let separator = "\u{1F}|\u{1F}"

    static func compositeID(scriptID: UUID, notificationID: String) -> String {
        scheme + scriptID.uuidString + separator + notificationID
    }

    private func split(_ composite: String) -> (scriptID: String, notificationID: String)? {
        guard composite.hasPrefix(Self.scheme) else { return nil }
        let body = String(composite.dropFirst(Self.scheme.count))
        guard let range = body.range(of: Self.separator) else { return nil }
        let scriptID = String(body[body.startIndex..<range.lowerBound])
        let notificationID = String(body[range.upperBound...])
        guard !scriptID.isEmpty else { return nil }
        return (scriptID, notificationID)
    }

    // MARK: - Pure option -> content mapping

    /// Map a GM_notification details object to UN content. Supported fields: title, text/message,
    /// silent. `fallbackTitle` (the script name) is used when no title is supplied, matching TM which
    /// shows the script name. Pure for testability. `image` is intentionally NOT attached: iOS UN
    /// image attachments require a LOCAL file, and fetching a remote image URL from a notification is
    /// an SSRF/exfil vector (same stance WebExtensionNotificationManager takes) — documented limit.
    static func notificationContent(from options: [String: Any],
                                    fallbackTitle: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let title = (options["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        content.title = title
        if let text = options["text"] as? String { content.body = text }
        else if let message = options["message"] as? String { content.body = message }
        let silent = (options["silent"] as? Bool) ?? false
        content.sound = silent ? nil : .default
        content.threadIdentifier = "brownbear.userscript"
        return content
    }
}

/// Nonisolated UNUserNotificationCenterDelegate forwarder, hopping every event onto the main actor.
private final class DelegateForwarder: NSObject, UNUserNotificationCenterDelegate {

    weak var manager: UserScriptNotificationManager?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let composite = response.notification.request.identifier
        let actionID = response.actionIdentifier
        Task { @MainActor [weak manager] in
            guard let manager else { completionHandler(); return }
            if UserScriptNotificationManager.owns(compositeID: composite) {
                manager.routeResponse(composite: composite, actionID: actionID)
            }
            completionHandler()
        }
    }
}
