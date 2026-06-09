//
//  WebExtensionBackgroundContext+BrowserData.swift
//  BrownBear
//
//  The background-worker bridge for the read-only browsing-data APIs — chrome.bookmarks,
//  chrome.history, chrome.sessions — backed by BrownBear's own stores via the host. These expose the
//  user's bookmarks / visited URLs / recently-closed tabs, so each call is GATED on the matching
//  manifest permission (bookmarks/history/sessions) BEFORE it reaches the host: a script that didn't
//  declare the permission gets a rejection, never the data (CLAUDE.md §5). Mirrors the __bb_tabs /
//  __bb_scripting pattern — hop to the main actor (stores + TabManager live there), then call back.
//

import Foundation
import JavaScriptCore

extension WebExtensionBackgroundContext {

    func installBrowserDataNatives(into context: JSContext) {
        // The manifest's declared permissions, captured by value (set once at boot, read-only after) so
        // the gate is race-free off the context queue. grantedPermissions (runtime-optional) is private;
        // bookmarks/history/sessions are required permissions extensions declare in the manifest.
        let manifestPermissions = cookiePermissions

        let browserData: @convention(block) (String, String, JSValue) -> Void = { [weak self] method, argsJSON, callback in
            guard let self else { return }
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any]) ?? [:]
            // Fail closed: an undeclared permission gets nothing (these read the user's browsing data).
            if let perm = WebExtensionBrowserData.requiredPermission(forMethod: method),
               !manifestPermissions.contains(perm) {
                self.callBack(callback, with: self.jsonString(
                    ["__bbError": "chrome.\(method) requires the \"\(perm)\" permission"]))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result: Any
                if let host = self.host {
                    result = await WebExtensionBackgroundContext.dispatchBrowserData(host: host, method: method, args: args)
                } else {
                    result = NSNull()
                }
                self.callBack(callback, with: self.jsonString(result))
            }
        }
        context.setObject(browserData, forKeyedSubscript: "__bb_browser_data" as NSString)
    }

    /// Route a gated browsing-data method to the host, mapping to the Chrome object shapes. Runs on the
    /// main actor (the stores are actors the host awaits; TabManager is main-isolated).
    @MainActor
    static func dispatchBrowserData(host: WebExtensionBridgeHost, method: String, args: [String: Any]) async -> Any {
        switch method {
        case "bookmarks.getTree":
            return await host.webExtBookmarksTree()
        case "bookmarks.search":
            // Chrome accepts a string or `{query}`; the JS shim sends the resolved text.
            return await host.webExtBookmarksSearch(query: (args["query"] as? String) ?? "")
        case "history.search":
            return await host.webExtHistorySearch(text: (args["text"] as? String) ?? "",
                                                  maxResults: (args["maxResults"] as? Int) ?? 0)
        case "sessions.getRecentlyClosed":
            return host.webExtSessionsRecentlyClosed(maxResults: (args["maxResults"] as? Int) ?? 0)
        case "sessions.restore":
            return host.webExtSessionsRestore(sessionId: args["sessionId"] as? String) ?? NSNull()
        case "bookmarks.create":
            return await host.webExtBookmarksCreate(title: (args["title"] as? String) ?? "",
                                                    url: (args["url"] as? String) ?? "") ?? NSNull()
        case "bookmarks.remove":
            await host.webExtBookmarksRemove(id: (args["id"] as? String) ?? "")
            return NSNull()
        case "history.addUrl":
            await host.webExtHistoryAddUrl(url: (args["url"] as? String) ?? "", title: args["title"] as? String)
            return NSNull()
        case "history.deleteUrl":
            await host.webExtHistoryDeleteUrl(url: (args["url"] as? String) ?? "")
            return NSNull()
        case "history.deleteRange":
            // startTime/endTime are epoch ms — both REQUIRED by Chrome's deleteRange, so the caller
            // always supplies them; a missing endTime collapses the range (deletes nothing) rather than
            // over-deleting.
            let start = (args["startTime"] as? Double) ?? 0
            let end = (args["endTime"] as? Double) ?? start
            await host.webExtHistoryDeleteRange(startMs: start, endMs: end)
            return NSNull()
        default:
            return ["__bbError": "unsupported browsing-data method '\(method)'"]
        }
    }
}
