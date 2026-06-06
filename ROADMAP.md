# BrownBear — Roadmap (autonomous build)

Sequenced, value-ordered. The lead (me) owns prioritization; default to top-down. Each item is one
or a few PR-sized slices. UIKit-only; never red CI.

## Phase A — Foundation
- [x] Autonomous-build scaffolding (PROGRESS.md, ROADMAP.md, DIRECTIVE.md, run-loop.sh, gitignore).
- [ ] Reference study → `reference/UIKIT_PATTERNS.md` (firefox-ios TabTray/containment, brave-ios
      programmatic toolbars/shields overlay, Orion dense toolbar/vertical tabs, Gear dev-tools HUD,
      Focus script-manager + floating player). reference/ gitignored; write original code only.

## Phase B — Migrate the dashboard off SwiftUI → programmatic UIKit
- [ ] B1. `DashboardContainerViewController` (UITabBarController-based) replacing `BrownBearDashboardView`
      TabView; presented from the browser menu; UIKit theme tokens (`BrownBearTheme`).
- [ ] B2. Scripts list: `ScriptsListViewController` (UICollectionView, list layout) + cell, replacing
      the SwiftUI Scripts tab + `ScriptRowView`; per-script `UISwitch`, swipe actions, add menu.
- [ ] B3. Logs: `LogsViewController` (UITableView) replacing `LogsView`, WITH the page/iframe/userscript
      source filter (folds in the logging feature) + level colors.
- [ ] B4. Background monitor → `BackgroundMonitorViewController`.
- [ ] B5. Extensions → `ExtensionsListViewController` (install file/Web Store, toggle, popup/options).
- [ ] B6. Script detail → `ScriptDetailViewController`.
- [ ] B7. Editor: keep Runestone `TextView` (UIKit); replace SwiftUI `ScriptEditorScreen`/`CodeEditorView`
      with `ScriptEditorViewController`.
- [ ] B8. Install card: `ScriptInstallViewController` replacing `ScriptInstallView`.
- [ ] B9. Delete the SwiftUI files + `DashboardTheme` (fold tokens into `BrownBearTheme`).

## Phase C — New UIKit HUDs (the marquee UI)
- [ ] C1. Dark console HUD overlay: real-time JS console (page + iframe + userscript), micro-typography,
      draggable/resizable, zero viewport lag. Capture page/iframe console natively (all-frames hook).
- [ ] C2. Gear-style compact bottom toolbar: script-run micro-badges, layout-inspector anchor,
      element/target selector.
- [ ] C3. Focus-style sliding script-manager cards (`UISheetPresentationController`, medium+large).

## Phase D — Runtime API gaps (native, UIKit-agnostic; UIKit for any surfaces)
- [ ] D1. `WebExtensionBridgeHost` keystone for chrome.* (tabs + per-frame eval).
- [ ] D2. chrome.tabs (query/get/create/update/remove) + background↔content `tabs.sendMessage` +
      content-script `storage.onChanged` + chrome.scripting + chrome.userScripts (MV3).
- [ ] D3. GM_registerMenuCommand (+ UIKit command menu), GM_notification (UNUserNotificationCenter),
      GM_cookie (WKHTTPCookieStore), GM_download, GM_getTab/saveTab, window.onurlchange.

## Phase E — Scale & R&D
- [ ] E1. Tab pooling: background-tab suspension + view-state serialization under memory pressure.
- [ ] E2. Mock script-heavy HTML suite to stress the GM layer; patch CI-surfaced bugs.
- [ ] E3. Editor Tree-sitter JS highlighting (TreeSitterJavaScriptRunestone).
- [ ] E4. Shrink docs "infeasible" list to only the genuinely-impossible.

## Honest scope notes
- Chrome-extension *runtime* on iOS/WebKit stays a compatibility layer (no Chromium engine); the
  `.crx`/store path is scoped to what WebKit allows + userscripts. Documented in docs/WEB_EXTENSIONS.md.
