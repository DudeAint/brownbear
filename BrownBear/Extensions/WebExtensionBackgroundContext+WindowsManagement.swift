//
//  WebExtensionBackgroundContext+WindowsManagement.swift
//  BrownBear
//
//  Split out of WebExtensionBackgroundContext.swift to keep that file under the 1000-line cap.
//  Houses the BACKGROUND worker's chrome.windows / chrome.management / chrome.permissions natives
//  plus runtime.openOptionsPage / runtime.setUninstallURL. These hop to the main actor to reach the
//  bridge host and BrownBearServices.shared (both @MainActor), then callBack onto this context's
//  serial `queue` with the JSON result — the same discipline as every other native block here.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    /// chrome.windows / chrome.management / chrome.permissions / chrome.proxy + the real
    /// runtime.openOptionsPage and runtime.setUninstallURL for the BACKGROUND worker.
    /// windows hop to the browser host on the main actor; management/permissions read the
    /// store + grants actors (off BrownBearServices.shared, which is @MainActor) then call
    /// back on this context's serial queue. chrome.proxy routes to WebExtensionProxyManager.
    func installWindowsManagementPermissionsNatives(into context: JSContext) {
        let windows: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any = self.host.map {
                    WebExtensionBackgroundContext.dispatchWindow(host: $0, method: method, args: args)
                } ?? NSNull()
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(windows, forKeyedSubscript: "__bb_windows" as NSString)

        let management: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let store = BrownBearServices.shared.webExtensionStore
                let result = await WebExtensionBackgroundContext.dispatchManagement(
                    store: store, selfID: self.extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(management, forKeyedSubscript: "__bb_management" as NSString)

        let permissions: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            Task { @MainActor [weak self] in
                guard let self else { return }
                let store = BrownBearServices.shared.webExtensionStore
                let grants = BrownBearServices.shared.webExtensionPermissionGrants
                let result = await WebExtensionBackgroundContext.dispatchPermissions(
                    store: store, grants: grants, extensionID: self.extensionID, method: method, args: args)
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(permissions, forKeyedSubscript: "__bb_permissions" as NSString)

        let openOptions: @convention(block) (JSValue) -> Void = { [weak self] callback in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ok = self.host?.webExtOpenOptionsPage(extensionID: self.extensionID) ?? false
                self.callBack(callback, with: ok ? "true" : "false")
            }
        }
        context.setObject(openOptions, forKeyedSubscript: "__bb_runtime_open_options" as NSString)

        let setUninstallURL: @convention(block) (String, JSValue) -> Void = { [weak self] url, callback in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let grants = BrownBearServices.shared.webExtensionPermissionGrants
                await grants.setUninstallURL(extensionID: self.extensionID, url: url)
                self.callBack(callback, with: nil)
            }
        }
        context.setObject(setUninstallURL, forKeyedSubscript: "__bb_runtime_set_uninstall_url" as NSString)

        // chrome.proxy.settings.set / .clear — wired as __bb_proxy(method, argsJSON, cb).
        // method is "set" or "clear". On "set", argsJSON is the ProxyConfig value object.
        // Gate: the extension MUST declare "proxy" in its manifest permissions; we check
        // against the store asynchronously (same Task hop used by __bb_permissions above).
        // On iOS < 17 the manager records the intent and returns nil (no error) so VPN
        // extensions proceed with their JS logic while not actually routing traffic —
        // logged once via logSink so the developer can see it in the Logs tab.
        let proxy: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let extID = self.extensionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                let store = BrownBearServices.shared.webExtensionStore
                let ext = await store.ext(for: extID)
                let manifest = ext?.manifest

                // Permission gate: fail closed if "proxy" is not declared.
                guard manifest?.permissions.contains("proxy") == true else {
                    let errJSON = self.jsonString(["error": "the \"proxy\" permission is not granted"])
                    self.callBack(callback, with: errJSON)
                    return
                }

                let proxyMgr = WebExtensionProxyManager.shared
                var errorString: String?

                if method == "set" {
                    let config = ((try? JSONSerialization.jsonObject(
                        with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
                    // Log once on pre-iOS-17 devices so the developer can see the limitation.
                    if #available(iOS 17.0, *) {
                        // Full proxy support available — no diagnostic needed.
                    } else {
                        self.logSink(self.makeLog(.info,
                            "chrome.proxy requires iOS 17+; proxy config recorded but not applied at the network layer"))
                    }
                    errorString = proxyMgr.apply(extensionID: extID, config: config)
                } else {
                    // "clear" (or any other method): reset to direct.
                    proxyMgr.clear(extensionID: extID)
                }

                if let err = errorString {
                    let errJSON = self.jsonString(["error": err])
                    self.callBack(callback, with: errJSON)
                } else {
                    self.callBack(callback, with: nil)
                }
            }
        }
        context.setObject(proxy, forKeyedSubscript: "__bb_proxy" as NSString)
    }

    /// Map a chrome.windows method + args to the bridge host, returning a JSON-serializable value.
    @MainActor
    private static func dispatchWindow(host: WebExtensionBridgeHost, method: String, args: [String: Any]) -> Any {
        let populate = (args["populate"] as? Bool) ?? false
        switch method {
        case "get", "getCurrent", "getLastFocused":
            return host.webExtWindow(populate: populate)
        case "getAll":
            return host.webExtAllWindows(populate: populate)
        case "create":
            return host.webExtCreateWindow(url: args["url"] as? String,
                                           active: (args["focused"] as? Bool) ?? true,
                                           populate: populate)
        case "update":
            return host.webExtUpdateWindow(populate: populate)
        default:
            return NSNull()   // remove et al. — no-op on a single, unclosable window
        }
    }

    /// chrome.management reads, off the WebExtensionStore actor.
    private static func dispatchManagement(store: WebExtensionStore, selfID: String,
                                           method: String, args: [String: Any]) async -> Any {
        switch method {
        case "getAll":
            return WebExtensionManagementInfo.allExtensionInfos(await store.all())
        case "get":
            guard let id = args["id"] as? String, let ext = await store.ext(for: id) else { return NSNull() }
            return WebExtensionManagementInfo.extensionInfo(for: ext)
        case "getSelf":
            guard let ext = await store.ext(for: selfID) else { return NSNull() }
            return WebExtensionManagementInfo.extensionInfo(for: ext)
        default:
            return NSNull()
        }
    }

    /// chrome.permissions reconciliation, off the store + grant actors. `request` now shows a user
    /// consent prompt (WebExtensionPermissionPrompt) before granting any NEW optional permission,
    /// replacing the previous silent auto-grant. Runs on the main actor (called from a @MainActor Task),
    /// so presenting the prompt and reading the store/grants is race-free here.
    @MainActor
    private static func dispatchPermissions(store: WebExtensionStore,
                                            grants: WebExtensionPermissionGrants,
                                            extensionID: String, method: String,
                                            args: [String: Any]) async -> Any {
        let ext = await store.ext(for: extensionID)
        let manifest = ext?.manifest
        let requested = WebExtensionManagementInfo.PermissionSet(payload: args)
        let granted = await grants.granted(extensionID: extensionID)
        switch method {
        case "getAll":
            return WebExtensionManagementInfo.effective(manifest: manifest, granted: granted).dictionary
        case "contains":
            return WebExtensionManagementInfo.contains(requested, manifest: manifest, granted: granted)
        case "request":
            guard let toGrant = WebExtensionManagementInfo.resolveRequest(requested, manifest: manifest) else {
                return false
            }
            // Prompt only for what isn't already held; an already-held request resolves true silently.
            let effective = WebExtensionManagementInfo.effective(manifest: manifest, granted: granted)
            var newlyRequested = toGrant
            newlyRequested.permissions.subtract(effective.permissions)
            newlyRequested.origins.subtract(effective.origins)
            guard await WebExtensionPermissionPrompt.request(extensionName: ext?.displayName ?? extensionID,
                                                             toGrant: newlyRequested) else { return false }
            await grants.grant(extensionID: extensionID, newlyRequested)
            return true
        case "remove":
            guard let remaining = WebExtensionManagementInfo.resolveRemove(requested, manifest: manifest, granted: granted) else {
                return false
            }
            await grants.setGranted(extensionID: extensionID, remaining)
            return true
        default:
            return NSNull()
        }
    }
}
