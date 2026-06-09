//
//  WebExtensionRuntime.swift
//  BrownBear
//
//  The coordinator for extension BACKGROUND execution (Module 6, Phase 2). It owns one
//  `WebExtensionBackgroundContext` per enabled extension that declares a background, reconciles that
//  set whenever extensions change, routes content-script → background runtime messages, and fans
//  chrome.storage changes out to the right worker's onChanged listeners.
//
//  A single instance lives on `BrownBearServices`; the content-script bridge (WebExtensionMessage-
//  Router) delivers messages through it, and it self-observes the change notifications so the
//  foreground engine doesn't have to know it exists.
//

import Foundation
import UIKit

// Not `final`: WebExtensionEventEmitterTests subclasses it (SpyRuntime) to capture the event fan-out
// without booting a JSContext. dispatchEventToAll is likewise overridable.
@MainActor
class WebExtensionRuntime {

    private let store: WebExtensionStore
    private let storage: WebExtensionStorage
    private let logStore: LogStore

    private var contexts: [String: WebExtensionBackgroundContext] = [:]
    private var observers: [NSObjectProtocol] = []

    /// chrome.runtime.connect/onConnect long-lived ports. Owned here because the runtime is the one
    /// object that reaches every surface (background workers + the routers that own content/page
    /// endpoints). The hub delegates background-side delivery back to this runtime (see the
    /// WebExtensionPortBackgroundDeliverer conformance), which routes to the right worker's context.
    let portHub = WebExtensionPortHub()

    /// chrome.offscreen documents (one hidden WKWebView per extension). Owned here because the runtime
    /// is the app-lifetime object that already holds `host` (the view container) and fans runtime
    /// messages to every page — an offscreen document is just another message-receiving page.
    let offscreenManager = WebExtensionOffscreenManager()

    /// chrome.downloads state (per-extension download records + URLSession tasks). Owned here so it can
    /// fan onCreated/onChanged/onErased into the owning worker and be torn down on unload.
    let downloadsManager = WebExtensionDownloadsManager()

    /// Live extension PAGES (popups/options) that want browser-pushed chrome.tabs/webNavigation
    /// events, held weakly so a dismissed page is skipped (and cleaned up) on the next fan-out.
    private final class WeakEventReceiver { weak var value: WebExtensionEventReceiver?; init(_ v: WebExtensionEventReceiver) { value = v } }
    private var eventReceivers: [ObjectIdentifier: WeakEventReceiver] = [:]
    /// Each running worker's granted permissions, cached so the webNavigation gate is synchronous.
    private var permissionsByExtension: [String: Set<String>] = [:]

    /// chrome.tabs bridge to the browser; pushed to every background context. Set after the browser
    /// view controller loads (contexts may already exist), so propagate to the live ones too.
    weak var host: WebExtensionBridgeHost? {
        didSet { for context in contexts.values { context.host = host } }
    }
    /// chrome.cookies bridge to the browser; pushed to every background context, same lifecycle as host.
    weak var cookieHost: WebExtensionCookieBridgeHost? {
        didSet { for context in contexts.values { context.cookieHost = cookieHost } }
    }
    private var didStart = false
    // Single-flight reconciliation: reload() is async and suspends at every actor await, so two
    // overlapping calls (the initial start() one and a change-notification one) could otherwise
    // both boot the same extension and leak the loser's JSContext/timers. We coalesce instead.
    private var isReloading = false
    private var reloadRequested = false

    init(store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         storage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage,
         logStore: LogStore = BrownBearServices.shared.logStore) {
        self.store = store
        self.storage = storage
        self.logStore = logStore
        self.portHub.backgroundDeliverer = self
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Begin observing change notifications and load the current background set. Idempotent.
    func start() {
        guard !didStart else { return }
        didStart = true

        observers.append(NotificationCenter.default.addObserver(
            forName: .brownBearExtensionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .brownBearExtensionStorageDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleStorageChange(note) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .brownBearExtensionCookieDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleCookieChange(note) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .brownBearExtensionNotificationEvent, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleNotificationEvent(note) }
        })
        // chrome.idle.onStateChanged: app foreground/background + device lock/unlock drive the idle state
        // (iOS can't observe true user idle). Coalesced so only real transitions fire. The lock
        // notification fires just before lock while applicationState is still .active, so we force the
        // "locked" state from the NOTIFICATION rather than recomputing (which would race the state change).
        let lockName = UIApplication.protectedDataWillBecomeUnavailableNotification
        for name: NSNotification.Name in [UIApplication.didBecomeActiveNotification,
                                          UIApplication.willResignActiveNotification,
                                          UIApplication.didEnterBackgroundNotification,
                                          UIApplication.protectedDataDidBecomeAvailableNotification,
                                          lockName] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] note in
                let forced = note.name == lockName ? "locked" : nil
                Task { @MainActor in self?.pushIdleStateIfChanged(forced: forced) }
            })
        }

        Task { await reload() }
    }

    /// Deliver chrome.idle.onStateChanged to every running worker when the state changes. `forced` pins
    /// the state for a notification whose meaning is unambiguous (lock), avoiding a recompute that races
    /// the underlying state transition; otherwise we recompute from app/device condition.
    private var lastIdleState: String?
    private func pushIdleStateIfChanged(forced: String? = nil) {
        let state = forced ?? WebExtensionBackgroundContext.currentIdleState()
        guard state != lastIdleState else { return }
        lastIdleState = state
        for context in contexts.values { context.fireIdleStateChanged(state) }
    }

    // MARK: - Message bus

    /// Deliver a `chrome.runtime.sendMessage` to its extension's other contexts and return the first
    /// listener's response (`["value": ...]`) or nil if nothing answered. Chrome delivers to every
    /// context of the extension (background worker + open popup/options pages) except the sender; the
    /// first context that answers wins. `senderToken` is the sending page's token (if a page sent it),
    /// so that page is skipped. Content scripts receive via tabs.sendMessage, not this fan-out.
    func sendRuntimeMessage(_ message: Any, sender: [String: Any], to extensionID: String,
                            senderToken: String? = nil, senderIsBackground: Bool = false) async -> [String: Any]? {
        // Track whether ANY context of this extension had a receiving onMessage listener. Chrome only
        // raises "Could not establish connection. Receiving end does not exist." when NOTHING received.
        var sawReceiver = false
        // Background worker first (the common responder), then open extension pages — but when the
        // BACKGROUND is the sender (chrome.runtime.sendMessage from the worker), skip it: Chrome never
        // delivers a context its own broadcast, and the worker fans out only to its pages (popup /
        // options / offscreen document).
        if !senderIsBackground, let context = contexts[extensionID] {
            if let response = await context.deliverRuntimeMessage(message: message, sender: sender) {
                // A `{__bbNoListener:true}` reply means the worker booted but registered no onMessage
                // listener — keep looking. Any other reply is an actual answer.
                if response["__bbNoListener"] == nil { return response }
            } else {
                sawReceiver = true   // had a listener that declined or never answered (channel existed)
            }
        }
        for box in eventReceivers.values {
            // Skip a registered-but-dead page (web view gone): it can't receive, so it must not count
            // toward `sawReceiver` — otherwise it would suppress the no-receiving-end lastError.
            guard let receiver = box.value, receiver.receiverExtensionID == extensionID,
                  receiver.isDeliverable else { continue }
            sawReceiver = true   // an open page of this extension exists to receive
            if let response = await receiver.deliverRuntimeMessage(message: message, sender: sender,
                                                                   senderToken: senderToken) {
                return response
            }
        }
        // Nobody answered. If no context had a receiving listener at all, surface Chrome's no-receiver
        // signal so the sending runtime can set chrome.runtime.lastError; otherwise the message was
        // received but declined → resolve to undefined with no error.
        return sawReceiver ? nil : ["__bbNoReceiver": true]
    }

    /// Deliver a USER_SCRIPT-world script's message to its worker's chrome.runtime.onUserScriptMessage
    /// (MV3 User Scripts channel). Only the background worker receives it (not pages). Returns the
    /// worker's `["value": …]` answer, or nil.
    func deliverUserScriptMessage(extensionID: String, message: Any, sender: [String: Any]) async -> [String: Any]? {
        await contexts[extensionID]?.fireUserScriptMessage(message: message, sender: sender)
    }

    /// Append a popup/options PAGE's forwarded console line / uncaught error to this extension's log,
    /// so an otherwise-invisible blank-page failure is diagnosable in the dashboard. `source: .page`.
    func logFromPage(extensionID: String, level: String, message: String) async {
        let name = await store.ext(for: extensionID)?.displayName
        let entry = LogEntry(scriptID: nil, scriptName: name,
                             level: LogEntry.Level(rawValue: level) ?? .info,
                             message: message, context: .foreground, source: .page)
        await logStore.append(entry)
    }

    /// Deliver chrome.action.onClicked to an extension's background worker (when the action has no
    /// popup). No-op if the extension has no running background context. `tab` is a chrome.tabs Tab
    /// record (or nil if there's no active tab).
    func fireActionClicked(extensionID: String, tab: [String: Any]?) {
        contexts[extensionID]?.fireActionClicked(tab: tab)
    }

    // MARK: - chrome.offscreen

    /// chrome.offscreen.createDocument — create the extension's single hidden offscreen document.
    /// Returns `[:]` on success or `["error": <message>]` for the worker's Promise to reject with.
    func createOffscreenDocument(extensionID: String, path: String, reasons: [String],
                                 justification: String) async -> [String: Any] {
        guard let ext = await store.ext(for: extensionID) else { return ["error": "Unknown extension."] }
        let container = host?.webExtOffscreenContainer()
        return await offscreenManager.createDocument(ext: ext, path: path, reasons: reasons,
                                                     justification: justification, container: container)
    }

    /// chrome.offscreen.hasDocument.
    func hasOffscreenDocument(extensionID: String) -> Bool {
        offscreenManager.hasDocument(extensionID: extensionID)
    }

    /// chrome.offscreen.closeDocument — returns false if there was no document to close.
    func closeOffscreenDocument(extensionID: String) -> Bool {
        offscreenManager.closeDocument(extensionID: extensionID)
    }

    // MARK: - chrome.downloads

    func downloadsDownload(extensionID: String, options: [String: Any]) -> [String: Any] {
        downloadsManager.download(extensionID: extensionID, options: options)
    }
    func downloadsSearch(extensionID: String, query: [String: Any]) -> [[String: Any]] {
        downloadsManager.search(extensionID: extensionID, query: query)
    }
    func downloadsCancel(extensionID: String, id: Int) -> Bool {
        downloadsManager.cancel(extensionID: extensionID, id: id)
    }
    func downloadsPause(extensionID: String, id: Int) -> Bool {
        downloadsManager.pause(extensionID: extensionID, id: id)
    }
    func downloadsResume(extensionID: String, id: Int) -> Bool {
        downloadsManager.resume(extensionID: extensionID, id: id)
    }
    func downloadsErase(extensionID: String, query: [String: Any]) -> [Int] {
        downloadsManager.erase(extensionID: extensionID, query: query)
    }
    func downloadsRemoveFile(extensionID: String, id: Int) -> Bool {
        downloadsManager.removeFile(extensionID: extensionID, id: id)
    }

    /// Deliver a chrome.downloads.onCreated/onChanged/onErased event to the owning extension's worker.
    func fireDownloadEvent(extensionID: String, kind: String, payload: Any) {
        contexts[extensionID]?.fireDownloadEvent(kind: kind, payload: JSONSanitize.string(payload))
    }

    /// chrome.runtime.getContexts — the extension's live contexts: its background worker plus every open
    /// page (popup / options / offscreen document, all of which are registered event receivers).
    /// `filter` honors `contextTypes` and `documentUrls` (the common cases; e.g. an extension checks
    /// `getContexts({contextTypes:['OFFSCREEN_DOCUMENT']})` before creating one).
    func getContexts(extensionID: String, filter: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if contexts[extensionID] != nil {
            out.append(["contextId": "background", "contextType": "BACKGROUND",
                        "documentUrl": NSNull(), "documentOrigin": NSNull(),
                        "frameId": -1, "tabId": -1, "windowId": -1, "incognito": false])
        }
        for box in eventReceivers.values {
            guard let receiver = box.value, receiver.receiverExtensionID == extensionID,
                  let record = receiver.contextRecord() else { continue }
            out.append(record)
        }
        if let types = filter["contextTypes"] as? [String], !types.isEmpty {
            out = out.filter { types.contains(($0["contextType"] as? String) ?? "") }
        }
        if let urls = filter["documentUrls"] as? [String], !urls.isEmpty {
            out = out.filter { ($0["documentUrl"] as? String).map(urls.contains) ?? false }
        }
        return out
    }

    /// The ids of running workers that CLAIM this `.user.js` via a webRequest.onBeforeRequest filter
    /// (detection only — does not invoke the listener). For listing install targets in the picker.
    func userScriptWebRequestManagerIDs(url: URL) async -> [String] {
        let urlString = url.absoluteString
        var ids: [String] = []
        // Sorted iteration: `contexts` is a Dictionary (undefined order); the picker/route order must be
        // deterministic so the offered target doesn't flip between runs.
        for extID in contexts.keys.sorted() {
            guard let context = contexts[extID] else { continue }
            if await context.hasUserScriptWebRequestListener(url: urlString) { ids.append(extID) }
        }
        return ids
    }

    /// Dispatch a `.user.js` navigation to ONE webRequest-based manager's listener (picker routing).
    func dispatchUserScript(extensionID: String, url: URL) async -> Bool {
        await contexts[extensionID]?.dispatchUserScriptWebRequest(url: url.absoluteString) ?? false
    }

    /// Deliver chrome.contextMenus.onClicked to an extension's background worker. No-op if the
    /// extension has no running background context. `info` is the OnClickData object; `tab` is a
    /// chrome.tabs Tab record (or nil). Chrome fires this event only in the background/event page.
    func fireContextMenuClicked(extensionID: String, info: [String: Any], tab: [String: Any]?) {
        contexts[extensionID]?.fireContextMenuClicked(info: info, tab: tab)
    }

    // MARK: - Browser-pushed events (chrome.tabs.* / chrome.webNavigation.*)

    /// Register a live extension page (popup/options) to receive browser-pushed events. Held weakly.
    func registerEventReceiver(_ receiver: WebExtensionEventReceiver) {
        eventReceivers[ObjectIdentifier(receiver)] = WeakEventReceiver(receiver)
    }

    func unregisterEventReceiver(_ receiver: WebExtensionEventReceiver) {
        eventReceivers.removeValue(forKey: ObjectIdentifier(receiver))
    }

    /// Fan one browser-pushed event out to every background worker and live popup of every enabled
    /// extension. `argsJSON` is the event's already-encoded argument array. `requiredPermission`
    /// (e.g. "webNavigation") gates delivery to extensions that declared it; nil = deliver to all
    /// (chrome.tabs.* needs no permission). Overridable so tests can spy on the fan-out.
    func dispatchEventToAll(name: String, argsJSON: String, requiredPermission: String? = nil) {
        for (id, context) in contexts {
            if let requiredPermission, permissionsByExtension[id]?.contains(requiredPermission) != true { continue }
            context.dispatchExtEvent(name: name, argsJSON: argsJSON)
        }
        for box in eventReceivers.values {
            guard let receiver = box.value else { continue }
            if let requiredPermission, !receiver.receiverPermissions.contains(requiredPermission) { continue }
            receiver.dispatchExtEvent(name: name, argsJSON: argsJSON)
        }
    }

    // MARK: - Reconciliation

    /// Bring the running set of background contexts in line with the enabled extensions. Coalesced:
    /// if a reload is requested while one is in flight, exactly one more pass runs afterward.
    func reload() async {
        if isReloading { reloadRequested = true; return }
        isReloading = true
        defer { isReloading = false }
        repeat {
            reloadRequested = false
            await performReload()
        } while reloadRequested
    }

    private func performReload() async {
        let enabled = await store.enabledExtensions()
        var wanted: [String: WebExtension] = [:]
        for ext in enabled where Self.hasBackground(ext) { wanted[ext.id] = ext }

        // Tear down contexts for extensions that are gone or disabled.
        for (id, context) in contexts where wanted[id] == nil {
            context.shutdown()
            contexts.removeValue(forKey: id)
            permissionsByExtension.removeValue(forKey: id)
            // Drop this extension's context-menu items so stale rows never show after disable/uninstall.
            BrownBearServices.shared.webExtensionContextMenuStore.forgetExtension(id)
            // Close any offscreen document — its worker is gone, so the hidden web view must not linger.
            offscreenManager.close(extensionID: id)
            // Cancel any in-flight downloads the gone worker started.
            downloadsManager.close(extensionID: id)
        }

        // Spin up newly enabled extensions.
        for (id, ext) in wanted where contexts[id] == nil {
            await startContext(for: ext)
        }
    }

    private static func hasBackground(_ ext: WebExtension) -> Bool {
        guard let background = ext.manifest?.background else { return false }
        return background.serviceWorker != nil || !background.scripts.isEmpty
    }

    private func startContext(for ext: WebExtension) async {
        guard let manifest = ext.manifest, let background = manifest.background else { return }

        // A module service worker is linked from its package in-context, so we pass the entry PATH
        // (and the ESM linker runtime) instead of pre-reading a single classic source.
        let isModuleWorker = background.isModule && background.serviceWorker != nil
        var source = ""
        var moduleEntry: String?
        if let serviceWorker = background.serviceWorker {
            if isModuleWorker {
                moduleEntry = serviceWorker
                // Confirm the entry exists up front so a typo'd manifest fails fast rather than at link.
                guard await store.text(extensionID: ext.id, path: serviceWorker) != nil else { return }
            } else {
                source = await store.text(extensionID: ext.id, path: serviceWorker) ?? ""
            }
        } else {
            for path in background.scripts {
                if let text = await store.text(extensionID: ext.id, path: path) { source += text + "\n;\n" }
            }
        }
        guard isModuleWorker || !source.isEmpty else { return }

        let messages = await loadMessages(ext, manifest: manifest)
        let logStore = self.logStore
        let context = WebExtensionBackgroundContext(
            extensionID: ext.id,
            extensionName: ext.displayName,
            storage: storage,
            logSink: { entry in Task { await logStore.append(entry) } })

        // Defense in depth against reentrancy: we released the MainActor at the awaits above, so a
        // concurrent pass may already have booted this extension. Re-check with NO await before the
        // assignment (atomic on the MainActor) and discard the loser so its timers/continuations are
        // torn down rather than orphaned.
        guard contexts[ext.id] == nil else {
            context.shutdown()
            return
        }
        context.host = host   // chrome.tabs bridge (may be nil until the browser VC loads)
        context.cookieHost = cookieHost   // chrome.cookies bridge (same lifecycle as host)
        // Cache this worker's granted permissions for the synchronous webNavigation event gate.
        let granted = Set(manifest.permissions)
        permissionsByExtension[ext.id] = granted
        context.setGrantedPermissions(granted)
        contexts[ext.id] = context
        // Synchronous, path-contained package reader for the ESM linker (the store actor's
        // `nonisolated fileSync` is safe to call off-actor on the worker's serial queue).
        let moduleSource: (@Sendable (String) -> Data?)?
        if moduleEntry != nil {
            let storeRef = store
            let extID = ext.id
            moduleSource = { path in storeRef.fileSync(extensionID: extID, path: path) }
        } else {
            moduleSource = nil
        }
        let install = Self.consumeInstallReason(ext.id, currentVersion: manifest.version)
        context.boot(runtimeJS: Self.backgroundRuntimeJS,
                     backgroundSource: source,
                     manifestJSON: ext.manifestJSON,
                     baseURL: ext.baseURLString,
                     messages: messages,
                     installReason: install.reason,
                     previousVersion: install.previousVersion,
                     moduleEntry: moduleEntry,
                     esmRuntimeJS: moduleEntry != nil ? Self.esmRuntimeJS : nil,
                     moduleSource: moduleSource)
    }

    /// The chrome.runtime.onInstalled detail for this boot, by comparing the stored last-booted version
    /// against the manifest's current version — exactly like Chrome:
    /// - first-ever boot of this id → `reason: "install"`, no previousVersion;
    /// - a later boot whose version differs from the stored one → `reason: "update"`, previousVersion;
    /// - same version already booted → no event (`nil`), so first-run setup doesn't re-run every launch.
    /// onStartup still fires on every boot (handled in boot()). The legacy `installedFired` flag is
    /// honored so extensions installed under the pre-version scheme don't spuriously re-fire `install`.
    static func consumeInstallReason(_ extensionID: String,
                                     currentVersion: String) -> (reason: String?, previousVersion: String?) {
        let versionKey = "brownbear.webext.installedVersion.\(extensionID)"
        let legacyKey = "brownbear.webext.installedFired.\(extensionID)"
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: versionKey) {
            guard stored != currentVersion else { return (nil, nil) }
            defaults.set(currentVersion, forKey: versionKey)
            return ("update", stored)
        }
        // No version recorded yet for this id.
        defaults.set(currentVersion, forKey: versionKey)
        if defaults.bool(forKey: legacyKey) { return (nil, nil) }   // already installed pre-versioning
        defaults.set(true, forKey: legacyKey)
        return ("install", nil)
    }

    // MARK: - storage.onChanged fan-out

    private func handleStorageChange(_ note: Notification) {
        guard let info = note.userInfo,
              let extensionID = info["extensionID"] as? String,
              let area = info["area"] as? String,
              let changes = info["changes"] as? [String: [String: String]],
              let context = contexts[extensionID] else { return }
        context.dispatchStorageChanged(area: area, changes: changes)
    }

    /// Fan a cookie change (one record) out to every background worker's chrome.cookies.onChanged.
    /// iOS has a single cookie store, so the change is global; a worker without the cookies permission
    /// simply has no listeners, so broadcasting to all is safe.
    private func handleCookieChange(_ note: Notification) {
        guard let change = note.userInfo?["change"] as? [String: Any] else { return }
        for context in contexts.values { context.dispatchCookieChanged(change: change) }
    }

    /// Deliver a chrome.notifications event to the originating extension's background worker.
    private func handleNotificationEvent(_ note: Notification) {
        guard let info = note.userInfo,
              let extensionID = info["extensionID"] as? String,
              let kind = info["kind"] as? String,
              let notificationID = info["notificationID"] as? String,
              let context = contexts[extensionID] else { return }
        context.dispatchNotificationEvent(kind: kind,
                                          notificationID: notificationID,
                                          byUser: (info["byUser"] as? Bool) ?? false,
                                          buttonIndex: (info["buttonIndex"] as? Int) ?? 0)
    }

    // MARK: - i18n messages

    private func loadMessages(_ ext: WebExtension, manifest: WebExtensionManifest) async -> [String: String] {
        guard let locale = manifest.defaultLocale,
              let data = await store.file(extensionID: ext.id, path: "_locales/\(locale)/messages.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (key, value) in json {
            if let entry = value as? [String: Any], let message = entry["message"] as? String {
                out[key] = message
            }
        }
        return out
    }

    // MARK: - Ports (background-side delivery)

    /// Relay port traffic the worker initiates or replies to — the worker side of a port is its
    /// JSContext, which only this runtime can touch. Called by the port hub on the main actor; the
    /// context hops to its own serial queue. A port to an extension with no running worker drops
    /// (nothing could have connected to it), matching Chrome's "no listener" outcome.
    func deliverPortConnectToWorker(extensionID: String, portId: String, name: String, senderJSON: String) {
        contexts[extensionID]?.dispatchPortConnect(portId: portId, name: name, senderJSON: senderJSON)
    }

    func deliverPortMessageToWorker(extensionID: String, portId: String, messageJSON: String) {
        contexts[extensionID]?.dispatchPortMessage(portId: portId, messageJSON: messageJSON)
    }

    func deliverPortDisconnectToWorker(extensionID: String, portId: String) {
        contexts[extensionID]?.dispatchPortDisconnect(portId: portId)
    }

    // MARK: - Runtime source

    /// The chrome.* background runtime JS, loaded once from the bundle.
    private static let backgroundRuntimeJS: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-webext-background", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* brownbear-webext-background.js missing */"
        }
        return source
    }()

    /// The ES-module linker runtime (acorn parser + brownbear-esm-linker), concatenated and loaded
    /// once, lazily — only an extension with a module service worker pays the ~110 KB acorn parse.
    /// acorn must precede the linker (the linker captures `globalThis.__bbAcorn` at load).
    private static let esmRuntimeJS: String = {
        let acorn = bundledJS("brownbear-acorn")
        let linker = bundledJS("brownbear-esm-linker")
        return acorn + "\n;\n" + linker
    }()

    private static func bundledJS(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* \(name).js missing */"
        }
        return source
    }
}

// MARK: - WebExtensionPortBackgroundDeliverer
//
// The port hub never imports JavaScriptCore; it asks the runtime to deliver background-side port
// callbacks, and the runtime forwards to the extension's worker context (which owns the JSContext).
extension WebExtensionRuntime: WebExtensionPortBackgroundDeliverer {
    func deliverPortConnect(extensionID: String, portId: String, name: String, senderJSON: String) {
        deliverPortConnectToWorker(extensionID: extensionID, portId: portId, name: name, senderJSON: senderJSON)
    }

    func deliverPortMessage(extensionID: String, portId: String, messageJSON: String) {
        deliverPortMessageToWorker(extensionID: extensionID, portId: portId, messageJSON: messageJSON)
    }

    func deliverPortDisconnect(extensionID: String, portId: String) {
        deliverPortDisconnectToWorker(extensionID: extensionID, portId: portId)
    }
}
