//
//  UserScriptMenuCommandStore.swift
//  BrownBear
//
//  Native backing for two per-tab userscript surfaces that ScriptMessageRouter delegates to, kept in
//  their own type so the router stays under the SwiftLint file/type-body limits:
//
//    • GM_registerMenuCommand / GM_unregisterMenuCommand — a script registers named commands that the
//      browser surfaces in the "•••" menu's "Script commands" section. Each registration is bound to the
//      exact injection that made it (its per-injection token, the web view + frame it runs in, and its
//      stable script UUID). Tapping a command in the menu fires the script's callback back into THAT
//      frame's isolated content world — never the page world, never another script. Registrations live
//      for the injection's lifetime; they are reaped when the web view's main frame (re)loads (the router
//      already purges that web view's sessions there) or the web view deallocates.
//
//    • GM_getTab / GM_saveTab / GM_listTabs — a per-tab, per-script in-memory object (Tampermonkey
//      parity). The object persists for the tab's lifetime and is namespaced by the script's UUID so
//      script A can never read script B's tab object (CLAUDE.md §5). GM_listTabs returns this script's
//      objects across every live tab, keyed by chrome-style tab id.
//
//  Trust boundary (CLAUDE.md §5): every value here arrives from untrusted JS. We never trust a
//  JS-supplied script id or tab id — identity is the native-bound session, and the chrome tab id is
//  resolved natively from the calling web view. Stored payloads are opaque JSON strings the script
//  serialized; we treat them as data and never evaluate them. Caps bound every dimension so a runaway
//  script cannot exhaust memory across the shared, app-lifetime store.
//

import Foundation
import WebKit

/// One menu command a userscript registered via GM_registerMenuCommand, with everything the menu needs
/// to render it and everything native needs to fire it back into the right injection.
@MainActor
struct UserScriptMenuCommand {
    /// The script's stable UUID (native-bound — for attributing the command and de-duping).
    let scriptID: UUID
    /// The script's display name (for the optional subtitle / accessibility).
    let scriptName: String
    /// The per-injection token of the registering session. Identifies the JS closure to fire into.
    let token: String
    /// The JS-minted id unique within that token, passed back verbatim to invoke the callback.
    let commandID: String
    /// The user-visible caption the script supplied.
    let title: String
    /// An optional single-character access key (rendered as a hint; iOS has no menu accelerators).
    let accessKey: String?
    /// Whether tapping the command should auto-close the menu (GM default: true).
    let autoClose: Bool
    /// The web view the registering injection runs in (weak — never pin a tab alive).
    weak var webView: WKWebView?
    /// The exact frame (iframe-aware) the injection runs in; nil = main frame.
    let frameInfo: WKFrameInfo?
    /// True when the registering script runs in the PAGE world (granted, VM-parity). A tap then fires back
    /// via window.__bbPageXHR(commandID, "menu") into WKContentWorld.page — routed to the vault-registered
    /// handler for that minted command id — rather than __brownbear.fireMenuCommand into the isolated world.
    var isPageWorld: Bool = false
}

/// App-lifetime, main-actor store for userscript menu commands and per-tab GM tab objects. Owned by
/// ScriptMessageRouter. All mutation happens on the main actor, matching the router.
@MainActor
final class UserScriptMenuCommandStore {

    // MARK: - Caps (fail-closed bounds; a script cannot grow these unbounded)

    /// Max menu commands a single injection (token) may register. Beyond this, the oldest is dropped.
    private static let maxCommandsPerToken = 50
    /// Max total commands across every tab/script, so the shared store can't grow without bound.
    private static let maxTotalCommands = 2000
    /// Max bytes of a single saved tab-object JSON payload.
    private static let maxTabObjectBytes = 256 * 1024
    /// Max distinct (tabId, scriptID) tab objects retained, evicting oldest first.
    private static let maxTabObjects = 4000

    // MARK: - Menu commands

    /// Registration order preserved, so the menu renders commands in the order the script added them
    /// and per-token eviction drops the oldest. Keyed lookups scan this small array (≤ a few thousand).
    private var commands: [UserScriptMenuCommand] = []

    /// Register (or replace, by token+commandID) a menu command. Replacing keeps relative position so a
    /// re-register with a changed title updates in place rather than jumping to the end.
    func registerCommand(_ command: UserScriptMenuCommand) {
        if let index = commands.firstIndex(where: { $0.token == command.token && $0.commandID == command.commandID }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
        enforceCommandCaps(forToken: command.token)
    }

    /// Remove one command by its registering token + JS-minted id. No-op if it was never registered.
    func unregisterCommand(token: String, commandID: String) {
        commands.removeAll { $0.token == token && $0.commandID == commandID }
    }

    /// Drop every command registered by the given token (the injection went away / re-registered fresh).
    func purgeCommands(token: String) {
        commands.removeAll { $0.token == token }
    }

    /// Drop every command belonging to a web view — called when its main frame (re)loads or it
    /// deallocates, mirroring the router's session purge so stale menu entries never linger. Also reaps
    /// any command whose web view already died.
    func purge(webView: WKWebView) {
        commands.removeAll { $0.webView == nil || $0.webView === webView }
    }

    /// The live commands registered by injections in `webView` (the active tab's web view, when the
    /// menu is built). Dead-web-view entries are filtered defensively. Order = registration order.
    func commands(in webView: WKWebView) -> [UserScriptMenuCommand] {
        commands.filter { $0.webView === webView }
    }

    /// Find one command by token + id, for firing it back. Returns nil if it was unregistered or its
    /// web view died.
    func command(token: String, commandID: String) -> UserScriptMenuCommand? {
        commands.first { $0.token == token && $0.commandID == commandID && $0.webView != nil }
    }

    private func enforceCommandCaps(forToken token: String) {
        // Per-token cap: drop this token's oldest until within budget.
        var tokenIndices = commands.indices.filter { commands[$0].token == token }
        while tokenIndices.count > Self.maxCommandsPerToken, let oldest = tokenIndices.first {
            commands.remove(at: oldest)
            tokenIndices = commands.indices.filter { commands[$0].token == token }
        }
        // Global cap: drop the globally oldest (preferring a dead web view) until within budget.
        while commands.count > Self.maxTotalCommands {
            if let deadIndex = commands.firstIndex(where: { $0.webView == nil }) {
                commands.remove(at: deadIndex)
            } else {
                commands.removeFirst()
            }
        }
    }

    // MARK: - Per-tab GM tab objects

    /// (chrome tabId, scriptID) → opaque JSON string the script saved. Namespaced by scriptID so a
    /// script never reads another's tab object. Insertion order tracked for FIFO eviction.
    private var tabObjects: [TabObjectKey: String] = [:]
    private var tabObjectOrder: [TabObjectKey] = []

    private struct TabObjectKey: Hashable { let tabID: Int; let scriptID: UUID }

    /// The saved tab object JSON for a script in a tab, or nil if it never saved one (the runtime then
    /// hands the script an empty object, Tampermonkey parity).
    func tabObject(tabID: Int, scriptID: UUID) -> String? {
        tabObjects[TabObjectKey(tabID: tabID, scriptID: scriptID)]
    }

    /// Persist a script's tab object for the tab's lifetime. Oversized payloads are rejected (fail
    /// closed). Returns true if stored, false if rejected for size.
    @discardableResult
    func saveTabObject(tabID: Int, scriptID: UUID, json: String) -> Bool {
        guard json.utf8.count <= Self.maxTabObjectBytes else { return false }
        let key = TabObjectKey(tabID: tabID, scriptID: scriptID)
        if tabObjects[key] == nil { tabObjectOrder.append(key) }
        tabObjects[key] = json
        enforceTabObjectCap()
        return true
    }

    /// Every saved tab object for `scriptID`, keyed by chrome tab id (GM_listTabs). The router maps
    /// these to the `{ tabId: object }` shape the runtime expects.
    func tabObjects(forScript scriptID: UUID) -> [Int: String] {
        var out: [Int: String] = [:]
        for (key, value) in tabObjects where key.scriptID == scriptID {
            out[key.tabID] = value
        }
        return out
    }

    /// Drop every saved tab object for a closed tab, so a reused chrome id can't surface stale data.
    func forgetTab(tabID: Int) {
        let dropped = Set(tabObjects.keys.filter { $0.tabID == tabID })
        guard !dropped.isEmpty else { return }
        for key in dropped { tabObjects.removeValue(forKey: key) }
        tabObjectOrder.removeAll { dropped.contains($0) }
    }

    private func enforceTabObjectCap() {
        while tabObjectOrder.count > Self.maxTabObjects {
            let evicted = tabObjectOrder.removeFirst()
            tabObjects.removeValue(forKey: evicted)
        }
    }
}
