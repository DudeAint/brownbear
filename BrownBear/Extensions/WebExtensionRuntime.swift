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

@MainActor
final class WebExtensionRuntime {

    private let store: WebExtensionStore
    private let storage: WebExtensionStorage
    private let logStore: LogStore

    private var contexts: [String: WebExtensionBackgroundContext] = [:]
    private var observers: [NSObjectProtocol] = []
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

        Task { await reload() }
    }

    // MARK: - Message bus

    /// Deliver a content-script `chrome.runtime.sendMessage` to its extension's background worker
    /// and return the listener's response (`["value": ...]`) or nil if nothing answered.
    func sendRuntimeMessage(_ message: Any, sender: [String: Any], to extensionID: String) async -> [String: Any]? {
        guard let context = contexts[extensionID] else { return nil }
        return await context.deliverRuntimeMessage(message: message, sender: sender)
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

        var source = ""
        if let serviceWorker = background.serviceWorker {
            source = await store.text(extensionID: ext.id, path: serviceWorker) ?? ""
        } else {
            for path in background.scripts {
                if let text = await store.text(extensionID: ext.id, path: path) { source += text + "\n;\n" }
            }
        }
        guard !source.isEmpty else { return }

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
        contexts[ext.id] = context
        context.boot(runtimeJS: Self.backgroundRuntimeJS,
                     backgroundSource: source,
                     manifestJSON: ext.manifestJSON,
                     baseURL: ext.baseURLString,
                     messages: messages,
                     firstInstall: Self.consumeFirstInstall(ext.id))
    }

    /// True exactly once per extension id (its first-ever boot), so chrome.runtime.onInstalled fires
    /// reason 'install' only then; every boot still fires onStartup. Ids are random per install, so a
    /// reinstall is naturally a fresh id and fires 'install' again.
    private static func consumeFirstInstall(_ extensionID: String) -> Bool {
        let key = "brownbear.webext.installedFired.\(extensionID)"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) { return false }
        defaults.set(true, forKey: key)
        return true
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
}
