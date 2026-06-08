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

    /// If an enabled userscript-manager extension claims this `.user.js` URL via a declarativeNetRequest
    /// `redirect` rule (ScriptCat registers one targeting `install.html?url=<original>`), the extension +
    /// the page to open. WebKit can't perform a DNR redirect of a main-frame request, so we evaluate the
    /// stored rule ourselves and open the computed page — exactly what the redirect would have done. The
    /// first enabled extension with a matching rule wins.
    @MainActor
    func userScriptInstallRedirect(for url: URL) async -> (ext: WebExtension, target: URL)? {
        let store = BrownBearServices.shared.webExtensionStore
        let dnr = BrownBearServices.shared.webExtensionDNRStore
        // Gather each enabled extension's DNR rules (session + dynamic first — Chrome's runtime-over-static
        // precedence — then enabled static rulesets), serialized to JSON so the matching (which runs an
        // UNTRUSTED regexFilter) can cross to a background task as a Sendable string.
        var candidates: [(id: String, rulesJSON: String)] = []
        var byID: [String: WebExtension] = [:]
        for ext in await store.enabledExtensions() {
            guard let manifest = ext.manifest else { continue }
            var rules = await dnr.getSessionRules(extensionID: ext.id)
            rules += await dnr.getDynamicRules(extensionID: ext.id)
            let manifestDefaults = manifest.declarativeNetRequest.filter(\.enabled).map(\.id)
            let enabledIDs = await dnr.enabledRulesetIDs(extensionID: ext.id, manifestDefaults: manifestDefaults)
            for ruleset in manifest.declarativeNetRequest where enabledIDs.contains(ruleset.id) {
                if let data = await store.file(extensionID: ext.id, path: ruleset.path),
                   let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    rules += arr
                }
            }
            guard !rules.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: rules),
                  let json = String(data: data, encoding: .utf8) else { continue }
            candidates.append((ext.id, json))
            byID[ext.id] = ext
        }
        guard !candidates.isEmpty else { return nil }

        // Run the match OFF the main actor: an extension's regexFilter is untrusted, so a pathological
        // (ReDoS) pattern must not freeze the UI. The await suspends the main actor (it keeps servicing the
        // UI); worst case the hand-off just doesn't resolve and the caller falls back to the native card.
        let urlString = url.absoluteString
        let matched: (id: String, target: String)? = await Task.detached(priority: .userInitiated) {
            for candidate in candidates {
                guard let candidateURL = URL(string: urlString),
                      let rules = (try? JSONSerialization.jsonObject(with: Data(candidate.rulesJSON.utf8))) as? [[String: Any]],
                      let redirect = UserScriptInstallRouter.redirect(for: candidateURL, extensionID: candidate.id, rules: rules)
                else { continue }
                return (candidate.id, redirect.target.absoluteString)
            }
            return nil
        }.value
        guard let matched, let target = URL(string: matched.target), let ext = byID[matched.id] else { return nil }
        return (ext, target)
    }

    /// Hand a `.user.js` URL to an installed userscript manager that claims it (Chrome behavior), or fall
    /// back to BrownBear's own install card. Async because it consults extensions' DNR rules; call it
    /// AFTER cancelling the navigation that hit the `.user.js`.
    @MainActor
    func handleUserScriptInstall(for url: URL) {
        Task { @MainActor in
            if let redirect = await self.userScriptInstallRedirect(for: url),
               let path = Self.extensionPageRelativePath(from: redirect.target) {
                // An MV3 declarativeNetRequest manager (ScriptCat) → open its computed install page.
                self.openExtensionPageTab(ext: redirect.ext, kind: .options, path: path, activate: true)
            } else if await BrownBearServices.shared.webExtensionRuntime.handleUserScriptNavigation(url: url) {
                // An MV2 webRequest manager (Violentmonkey) took it and opens its own confirm page.
            } else {
                self.presentScriptInstall(for: url)
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
