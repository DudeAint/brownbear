//
//  BrownBearBrowserViewController+WebExtensions.swift
//  BrownBear
//
//  The browser's implementation of WebExtensionBridgeHost — chrome.tabs over TabManager. Tab records
//  use the chrome shape (integer id from the registry, windowId 1 — iOS is single-window). Split into
//  its own file to keep the controller under the SwiftLint length limit; the members it touches
//  (tabManager, webExtTabRegistry, loadNewTabPage) are internal for cross-file access.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController: WebExtensionBridgeHost {

    func webExtQueryTabs(_ query: [String: Any]) -> [[String: Any]] {
        var tabs = tabManager.tabs
        if let active = query["active"] as? Bool {
            tabs = tabs.filter { ($0.id == tabManager.activeTabID) == active }
        }
        if let incognito = query["incognito"] as? Bool {
            tabs = tabs.filter { $0.isPrivate == incognito }
        }
        let patterns = urlPatterns(from: query["url"])
        if !patterns.isEmpty {
            let matcher = URLMatcher(matches: patterns, includes: [], excludes: [], excludeMatches: [])
            tabs = tabs.filter { tab in tab.state.url.map { matcher.matches($0.absoluteString) } ?? false }
        }
        return tabs.map(webExtTabRecord)
    }

    func webExtTab(extTabId: Int?) -> [String: Any]? {
        resolveTab(extTabId).map(webExtTabRecord)
    }

    /// chrome.search.query — resolve `text` against the user's default search engine and open the
    /// results per `disposition`. Uses the SAME encoding/template the omnibox uses, so a query from an
    /// extension behaves identically to one typed in the bar. A blank query is ignored (Chrome no-ops it).
    func webExtSearchQuery(text: String, disposition: String?, extTabId: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Query-value encoding: alphanumerics + unreserved, matching the omnibox's stricter set (NOT
        // `.urlQueryAllowed`, which leaves `&=` unescaped and would corrupt the query string).
        var queryAllowed = CharacterSet.alphanumerics
        queryAllowed.insert(charactersIn: "-._~")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? trimmed
        let template = AppSettings.searchEngine.template
        guard let url = URL(string: template.replacingOccurrences(of: "%@", with: encoded)) else { return }
        switch (disposition ?? "CURRENT_TAB").uppercased() {
        case "NEW_TAB", "NEW_WINDOW":   // iOS is single-window → NEW_WINDOW opens a new tab.
            _ = webExtCreateTab(url: url.absoluteString, active: true)
        default:                         // CURRENT_TAB — the targeted tab, or the active one.
            _ = webExtUpdateTab(extTabId: extTabId, url: url.absoluteString, active: true)
        }
    }

    // MARK: - chrome.bookmarks / history / sessions (read-only browsing data)

    func webExtBookmarksTree() async -> [[String: Any]] {
        let bookmarks = await BrownBearServices.shared.bookmarkStore.all()
        return WebExtensionBrowserData.bookmarkTree(from: bookmarks)
    }

    func webExtBookmarksSearch(query: String) async -> [[String: Any]] {
        let bookmarks = await BrownBearServices.shared.bookmarkStore.all()
        return WebExtensionBrowserData.bookmarkSearch(query, in: bookmarks)
    }

    func webExtHistorySearch(text: String, maxResults: Int) async -> [[String: Any]] {
        let limit = maxResults > 0 ? maxResults : 100   // Chrome's default maxResults is 100
        let store = BrownBearServices.shared.historyStore
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank query means "most recent" in Chrome's history.search; otherwise full-text match.
        let entries = trimmed.isEmpty ? await store.recent(limit: limit) : await store.search(trimmed, limit: limit)
        return WebExtensionBrowserData.historyItems(from: entries)
    }

    func webExtSessionsRecentlyClosed(maxResults: Int) -> [[String: Any]] {
        let limit = maxResults > 0 ? maxResults : 25
        let closed = Array(tabManager.recentlyClosed.prefix(limit))
        return WebExtensionBrowserData.sessionRecords(from: closed)
    }

    func webExtSessionsRestore(sessionId: String?) -> [String: Any]? {
        let closed = tabManager.recentlyClosed
        guard let index = WebExtensionBrowserData.restoreIndex(sessionId: sessionId, closedCount: closed.count) else {
            return nil
        }
        let record = closed[index]
        tabManager.createTab(loading: record.url)   // reopen (mirrors the tab grid's Recently Closed action)
        return WebExtensionBrowserData.sessionRecords(from: [record]).first
    }

    func webExtTabRecord(forWebView webView: WKWebView) -> [String: Any]? {
        // A content script's message arrives on the tab's own web view; a popup/options page's does not
        // map to any tab here, so the caller (the MessageSender builder) correctly omits `tab` for it.
        guard let tab = tabManager.tabs.first(where: { $0.webView === webView }) else { return nil }
        return webExtTabRecord(tab)
    }

    /// The page-relative path (file path + query + fragment) of a `chrome-extension://<id>/…` URL, for
    /// `openExtensionPageTab`'s `path` override. The query + fragment MUST survive: extensions open pages
    /// like `install.html?uuid=<id>` and read `window.location.search` (ScriptCat's install page does);
    /// dropping it loaded the page with no params so its lookup found nothing. The scheme handler resolves
    /// files by path only, so the suffix is harmless to resource loading. Nil for a bare-origin URL.
    nonisolated static func extensionPageRelativePath(from url: URL) -> String? {
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if let query = url.query { path += "?" + query }
        if let fragment = url.fragment { path += "#" + fragment }
        return path.isEmpty ? nil : path
    }

    /// Every installed userscript-manager extension that CLAIMS this `.user.js` — as a hand-off target the
    /// install picker can offer. A manager claims it either via a declarativeNetRequest `redirect` rule
    /// (ScriptCat — we evaluate it since WebKit can't redirect a main-frame request) or a
    /// `webRequest.onBeforeRequest` filter (Violentmonkey). Each target's `route` opens that manager's own
    /// install/confirm flow. Detection only — nothing is invoked here.
    @MainActor
    func userScriptInstallTargets(for url: URL) async -> [ScriptInstallTarget] {
        let store = BrownBearServices.shared.webExtensionStore
        let dnr = BrownBearServices.shared.webExtensionDNRStore
        let runtime = BrownBearServices.shared.webExtensionRuntime
        var byID: [String: WebExtension] = [:]
        for ext in await store.enabledExtensions() { byID[ext.id] = ext }

        // --- declarativeNetRequest managers (ScriptCat). Gather rules, then match OFF the main actor (an
        //     extension's regexFilter is untrusted; a pathological pattern must not freeze the UI). ---
        // Iterate by sorted id so the target/picker order is deterministic — `byID.values` (and the runtime's
        // `contexts` dict) have undefined iteration order, which would make `routeToSingleManager` and the
        // picker's button order flip across runs / OS versions / extension-state changes.
        var candidates: [(id: String, rulesJSON: String)] = []
        for id in byID.keys.sorted() {
            guard let ext = byID[id], let manifest = ext.manifest else { continue }
            var rules = await dnr.getSessionRules(extensionID: ext.id)
            rules += await dnr.getDynamicRules(extensionID: ext.id)
            let manifestDefaults = manifest.declarativeNetRequest.filter(\.enabled).map(\.id)
            let enabledIDs = await dnr.enabledRulesetIDs(extensionID: ext.id, manifestDefaults: manifestDefaults)
            for ruleset in manifest.declarativeNetRequest where enabledIDs.contains(ruleset.id) {
                if let data = await store.file(extensionID: ext.id, path: ruleset.path),
                   let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { rules += arr }
            }
            guard !rules.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: rules),
                  let json = String(data: data, encoding: .utf8) else { continue }
            candidates.append((ext.id, json))
        }
        let urlString = url.absoluteString
        let dnrMatches: [(id: String, target: String)] = await Task.detached(priority: .userInitiated) {
            var out: [(String, String)] = []
            for candidate in candidates {
                guard let candidateURL = URL(string: urlString),
                      let rules = (try? JSONSerialization.jsonObject(with: Data(candidate.rulesJSON.utf8))) as? [[String: Any]],
                      let redirect = UserScriptInstallRouter.redirect(for: candidateURL, extensionID: candidate.id, rules: rules)
                else { continue }
                out.append((candidate.id, redirect.target.absoluteString))
            }
            return out
        }.value

        var targets: [ScriptInstallTarget] = []
        var seen = Set<String>()
        for (id, targetString) in dnrMatches {
            guard !seen.contains(id), let ext = byID[id], let target = URL(string: targetString),
                  let path = Self.extensionPageRelativePath(from: target) else { continue }
            seen.insert(id)
            targets.append(ScriptInstallTarget(name: ext.displayName, route: { [weak self] in
                self?.openExtensionPageTab(ext: ext, kind: .options, path: path, activate: true)
            }))
        }
        // --- webRequest managers (Violentmonkey): dispatch the navigation into the chosen worker's listener.
        for id in await runtime.userScriptWebRequestManagerIDs(url: url) where !seen.contains(id) {
            guard let ext = byID[id] else { continue }
            seen.insert(id)
            targets.append(ScriptInstallTarget(name: ext.displayName, route: {
                Task { @MainActor in _ = await runtime.dispatchUserScript(extensionID: id, url: url) }
            }))
        }
        return targets
    }

    /// Handle a `.user.js` navigation: per the user's install-target policy, show BrownBear's install sheet
    /// (with hand-off buttons for every installed manager that claims it), route straight to a manager, or
    /// just show the native card. Call AFTER cancelling the navigation that hit the `.user.js`.
    @MainActor
    func handleUserScriptInstall(for url: URL) {
        Task { @MainActor in
            let targets = await self.userScriptInstallTargets(for: url)
            switch AppSettings.userScriptInstallPolicy.decision(managerCount: targets.count) {
            case .nativeCard:
                self.presentScriptInstall(for: url)
            case .routeToSingleManager:
                targets.first?.route()
            case .picker(let showNativeInstall):
                self.presentScriptInstall(for: url, managerTargets: targets, showNativeInstall: showNativeInstall)
            }
        }
    }

    func webExtCreateTab(url: String?, active: Bool) -> [String: Any] {
        // A chrome-extension://<id>/<path> URL needs the per-extension scheme handler + chrome.* page
        // bridge a normal tab lacks (else it loads blank). Route it to the real extension-page tab. The
        // target extension is the URL's host; resolving it is async (the store is an actor), so we kick
        // it off and return a provisional record (chrome.tabs.create's result; callers rarely need the id).
        if let url, let parsed = URL(string: url),
           parsed.scheme == WebExtensionSchemeHandler.scheme,
           let extID = parsed.host, ChromeWebStore.isExtensionID(extID) {
            let path = Self.extensionPageRelativePath(from: parsed)
            Task { @MainActor in
                guard let ext = await BrownBearServices.shared.webExtensionStore.ext(for: extID) else { return }
                openExtensionPageTab(ext: ext, kind: .options, path: path, activate: active)
            }
            return ["id": -1, "url": url, "active": active, "windowId": Self.webExtWindowID, "index": tabManager.count]
        }
        let target = url.flatMap(Self.navigableURL)
        let tab = tabManager.createTab(loading: target, activate: active)
        tab.delegate = self
        if target == nil {
            loadNewTabPage(in: tab)
        } else {
            tab.loadPendingURLIfNeeded()
        }
        return webExtTabRecord(tab)
    }

    func webExtUpdateTab(extTabId: Int?, url: String?, active: Bool?) -> [String: Any]? {
        guard let tab = resolveTab(extTabId) else { return nil }
        if let target = url.flatMap(Self.navigableURL) {
            tab.delegate = self
            tab.load(target)
        }
        if active == true {
            tabManager.setActiveTab(tab)
        }
        return webExtTabRecord(tab)
    }

    func webExtRemoveTabs(extTabIds: [Int]) {
        for extID in extTabIds {
            guard let uuid = webExtTabRegistry.uuid(for: extID) else { continue }
            tabManager.closeTab(id: uuid)
            webExtTabRegistry.forget(uuid: uuid)
        }
    }

    func webExtReloadTab(extTabId: Int?, bypassCache: Bool) {
        resolveTab(extTabId)?.reload()
    }

    // MARK: - chrome.scripting

    func webExtExecuteScript(extTabId: Int?, world: String, code: String) async -> [[String: Any]] {
        guard let tab = resolveTab(extTabId) else { return [] }
        let contentWorld: WKContentWorld = (world.uppercased() == "MAIN") ? .page : injection.contentWorld
        let value: Any? = await withCheckedContinuation { continuation in
            BBEvaluateJavaScriptForResult(tab.webView, code, contentWorld) { result, _ in
                continuation.resume(returning: result)
            }
        }
        // One frame on iOS (the main frame); chrome's shape is an array of InjectionResult.
        return [["result": value ?? NSNull(), "frameId": 0]]
    }

    func webExtInsertCSS(extTabId: Int?, css: String) {
        guard let tab = resolveTab(extTabId) else { return }
        let literal = Self.jsStringLiteral(css)
        let js = "(function(){var s=document.createElement('style');"
            + "s.setAttribute('data-brownbear-ext-css','1');s.textContent=\(literal);"
            + "(document.head||document.documentElement).appendChild(s);})()"
        BBEvaluateJavaScript(tab.webView, js, .page)
    }

    func webExtRemoveCSS(extTabId: Int?, css: String) {
        guard let tab = resolveTab(extTabId) else { return }
        let literal = Self.jsStringLiteral(css)
        let js = "(function(){var c=\(literal);"
            + "var styles=document.querySelectorAll('style[data-brownbear-ext-css=\"1\"]');"
            + "for(var i=0;i<styles.length;i++){if(styles[i].textContent===c){styles[i].remove();}}})()"
        BBEvaluateJavaScript(tab.webView, js, .page)
    }

    // MARK: - chrome.tabs.sendMessage

    func webExtSendMessageToTab(extensionID: String, extTabId: Int?, message: Any, frameId: Int?) async -> Any? {
        guard let tab = resolveTab(extTabId) else { return nil }
        // The shared content router (on InjectionOrchestrator) owns the content sessions for this tab,
        // so delivery flows through it regardless of which surface (popup/background/content) sent the
        // message — each of those has its own router with no content sessions of its own.
        return await injection.webExtSendMessageToTab(extensionID: extensionID,
                                                      webView: tab.webView,
                                                      message: message,
                                                      frameId: frameId)
    }

    // MARK: - Helpers

    /// The title for an extension's overflow-menu (quick-look) action row. Resolves any `__MSG_*__`
    /// i18n placeholder in the action title (a manifest `default_title` is often `__MSG_extName__`);
    /// a no-op for already-final titles set via chrome.action.setTitle. Falls back to the extension's
    /// (already-resolved) display name when the action declares no title.
    static func webExtMenuActionTitle(_ resolvedTitle: String, ext: WebExtension) -> String {
        let raw = resolvedTitle.isEmpty ? ext.displayName : resolvedTitle
        return WebExtensionLocalizer.resolve(raw, extensionID: ext.id, defaultLocale: ext.manifest?.defaultLocale)
    }

    /// Encode a Swift string as a safe JS string literal (quotes included) via JSON.
    private static func jsStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string], options: []),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        // json is `["...escaped..."]`; strip the surrounding brackets to get the bare string literal.
        return String(json.dropFirst().dropLast())
    }

    /// The chrome.tabs Tab record for a tab (single-window, so windowId is always 1).
    func webExtTabRecord(_ tab: Tab) -> [String: Any] {
        let index = tabManager.tabs.firstIndex { $0.id == tab.id } ?? 0
        let isActive = tab.id == tabManager.activeTabID
        return [
            "id": webExtTabRegistry.id(for: tab.id),
            "index": index,
            "windowId": 1,
            "active": isActive,
            "highlighted": isActive,
            "selected": isActive,
            "pinned": false,
            "audible": false,
            "discarded": false,
            "incognito": tab.isPrivate,
            "url": tab.state.url?.absoluteString ?? "",
            "title": tab.state.displayTitle,
            "status": tab.state.isLoading ? "loading" : "complete"
        ]
    }

    /// Resolve a chrome tab id to a Tab; `nil` means the active tab (chrome's default for most APIs).
    private func resolveTab(_ extTabId: Int?) -> Tab? {
        guard let extTabId else { return tabManager.activeTab }
        guard let uuid = webExtTabRegistry.uuid(for: extTabId) else { return nil }
        return tabManager.tab(for: uuid)
    }

    /// chrome.tabs.captureVisibleTab — snapshot the active tab's web view to a `data:` URL. The gate
    /// (`permit`) is re-checked against THIS captured tab's current URL right before the snapshot, so a
    /// tab switch between the worker's check and the capture can't leak an unauthorized tab's pixels.
    func webExtCaptureVisibleTab(format: String, quality: Int, permit: (String?) -> Bool) async -> String? {
        guard let tab = tabManager.activeTab,
              tab.webView.bounds.width > 0, tab.webView.bounds.height > 0,
              permit(tab.webView.url?.absoluteString) else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let image: UIImage? = await withCheckedContinuation { continuation in
            tab.webView.takeSnapshot(with: config) { image, _ in continuation.resume(returning: image) }
        }
        guard let image else { return nil }
        let lower = format.lowercased()
        if lower == "jpeg" || lower == "jpg" {
            let q = CGFloat(max(0, min(100, quality))) / 100.0
            guard let data = image.jpegData(compressionQuality: q) else { return nil }
            return "data:image/jpeg;base64,\(data.base64EncodedString())"
        }
        guard let data = image.pngData() else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    private func urlPatterns(from value: Any?) -> [String] {
        if let single = value as? String { return [single] }
        if let many = value as? [String] { return many }
        return []
    }

    /// Only navigate to http(s)/about — never let an extension drive the browser to file:// etc.
    private static func navigableURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "about"].contains(scheme) else { return nil }
        return url
    }
}
