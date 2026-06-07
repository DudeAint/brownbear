//
//  BrownBearBrowserViewController+SiteShields.swift
//  BrownBear
//
//  Wires the omnibox lock/shield glyph to the Site Info + Shields popover. Builds the panel state
//  from the active tab's navigation state overlaid with the host's stored SiteSettings, presents the
//  popover anchored to the lock, and applies each toggle to REAL effect:
//    • Content blocking → records the host's shields choice and recompiles the content rule lists so
//      a shields-down host is excluded from every extension's declarativeNetRequest rules and a
//      shields-up host gets BrownBear's built-in tracker list (then reloads from origin).
//    • JavaScript      → seeds the tab's per-navigation `allowsContentJavaScript` and reloads.
//    • Desktop site    → reuses the existing prefersDesktop lever and reloads.
//
//  Split out of the main controller to stay under the SwiftLint length limit; the shared members it
//  reaches (tabManager, omnibox, refreshChrome via reload) are internal.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController {

    // MARK: - Presentation

    /// Present the Site Info + Shields panel as a popover anchored to the omnibox lock glyph. No-op
    /// for tabs with no real URL (the New Tab page has no per-site scope) or while editing.
    func presentSiteShields() {
        guard presentedViewController == nil,
              let tab = tabManager.activeTab,
              let url = tab.state.url,
              let host = SiteSettingsKey.normalizedHost(for: url) else { return }

        let anchor = omnibox.lockGlyphAnchorView
        let sourceRect = anchor.bounds
        Task { @MainActor in
            let stored = await BrownBearServices.shared.siteSettingsStore.settings(for: url)
            // The tab may have navigated away during the actor hop — re-check before presenting.
            guard tabManager.activeTab === tab, tabManager.activeTab?.state.url == url,
                  presentedViewController == nil else { return }
            let state = Self.makeShieldsState(host: host,
                                              displayHost: url.host ?? host,
                                              navigation: tab.state,
                                              scheme: url.scheme?.lowercased() ?? "",
                                              stored: stored)
            let controller = SiteShieldsViewController(state: state, delegate: self)
            present(controller.makePopover(sourceView: anchor, sourceRect: sourceRect), animated: true)
        }
    }

    /// Fold the stored per-host override over the app defaults into the effective switch states.
    private static func makeShieldsState(host: String, displayHost: String,
                                         navigation: NavigationState, scheme: String,
                                         stored: SiteSettings) -> SiteShieldsState {
        SiteShieldsState(
            host: host,
            displayHost: displayHost.hasPrefix("www.") ? String(displayHost.dropFirst(4)) : displayHost,
            isSecure: navigation.hasOnlySecureContent,
            scheme: scheme,
            contentBlockingOn: stored.blockContent ?? true,
            contentBlockingPinned: stored.blockContent != nil,
            javaScriptOn: stored.allowJavaScript ?? true,
            javaScriptPinned: stored.allowJavaScript != nil,
            desktopSiteOn: stored.desktopUA ?? false,
            desktopSitePinned: stored.desktopUA != nil)
    }
}

// MARK: - SiteShieldsDelegate

extension BrownBearBrowserViewController: SiteShieldsDelegate {

    func siteShields(_ controller: SiteShieldsViewController, didSet toggle: SiteShieldsToggle, isOn: Bool) {
        guard let tab = tabManager.activeTab, let url = tab.state.url else { return }
        switch toggle {
        case .contentBlocking:
            // Pin the explicit choice (true = shields up, false = shields down) for this host.
            Task {
                await BrownBearServices.shared.siteSettingsStore.setBlockContent(isOn, for: url)
                // Recompile so the host is added to / removed from the rule lists' exclusions, then
                // reload from origin so the page re-requests through the updated rules.
                await MainActor.run {
                    self.injection.refreshExtensionContentBlockers()
                    self.reloadActiveTabFromOrigin()
                }
            }
        case .javaScript:
            tab.prefersJavaScriptDisabled = !isOn
            Task {
                await BrownBearServices.shared.siteSettingsStore.setAllowJavaScript(isOn, for: url)
                await MainActor.run { self.reloadActiveTabFromOrigin() }
            }
        case .desktopSite:
            tab.prefersDesktop = isOn
            tab.webView.customUserAgent = isOn ? Self.desktopSafariUserAgent : nil
            Task {
                await BrownBearServices.shared.siteSettingsStore.setDesktopUA(isOn, for: url)
                await MainActor.run { self.reloadActiveTabFromOrigin() }
            }
        }
    }

    func siteShieldsDidRequestReset(_ controller: SiteShieldsViewController) {
        guard let tab = tabManager.activeTab, let url = tab.state.url else { return }
        tab.prefersDesktop = false
        tab.prefersJavaScriptDisabled = false
        tab.webView.customUserAgent = nil
        Task {
            await BrownBearServices.shared.siteSettingsStore.clear(for: url)
            await MainActor.run {
                self.injection.refreshExtensionContentBlockers()
                self.reloadActiveTabFromOrigin()
            }
        }
    }

    /// Re-request the active page from origin so a freshly changed per-site preference (JS, desktop,
    /// blocking) actually applies — `reload()` can serve cache and skip re-evaluating preferences.
    private func reloadActiveTabFromOrigin() {
        guard let tab = tabManager.activeTab else { return }
        if let url = tab.webView.url {
            tab.webView.load(URLRequest(url: url))
        } else {
            tab.webView.reloadFromOrigin()
        }
    }
}

// MARK: - Per-site preference seeding (called from the navigation delegate)

extension BrownBearBrowserViewController {

    /// Resolve and cache the host's stored per-site preferences onto the tab around its load. The JS
    /// flag applied by `decidePolicyFor` for THIS navigation reflects the tab's last-known state; the
    /// store read here is async, so on the first cold visit to a JS-disabled host the flag flips after
    /// the policy decision — when that happens we reload ONCE so the remembered "JavaScript off" choice
    /// is honored (no blanket double-load: the reload fires only on a real mismatch). Private tabs never
    /// read or write per-site prefs. Called from `decidePolicyFor` for the main frame.
    func seedSiteSettings(for tab: Tab, url: URL) {
        guard !tab.isPrivate else {
            tab.prefersJavaScriptDisabled = false
            return
        }
        let wasJavaScriptDisabled = tab.prefersJavaScriptDisabled
        Task { @MainActor in
            let stored = await BrownBearServices.shared.siteSettingsStore.settings(for: url)
            // Only mutate if this is still the tab's destination, so a later navigation isn't clobbered.
            guard tab.webView.url?.host == url.host || tab.state.url?.host == url.host else { return }
            let nowJavaScriptDisabled = (stored.allowJavaScript == false)
            tab.prefersJavaScriptDisabled = nowJavaScriptDisabled
            if let desktop = stored.desktopUA {
                tab.prefersDesktop = desktop
                // Pin the matching UA so a sniffing site is consistent with the rendered content mode.
                // Clearing to nil (mobile) is safe: the Chrome-Web-Store override owns its own UA path.
                tab.webView.customUserAgent = desktop ? Self.desktopSafariUserAgent : nil
            }
            // The in-flight load already evaluated JavaScript with the previous flag. If the remembered
            // choice disables JS but the load allowed it, re-request so the new preference takes effect.
            if nowJavaScriptDisabled, !wasJavaScriptDisabled, tab === tabManager.activeTab {
                tab.webView.load(URLRequest(url: url))
            }
        }
    }
}

/// Host normalization shared by the Shields UI and the content blocker, matching SiteSettingsStore's
/// internal key: lowercased, leading "www." stripped. Kept here (not private in the store) so the
/// per-site shields-down host set fed to the content blocker uses the identical scope.
enum SiteSettingsKey {
    static func normalizedHost(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
