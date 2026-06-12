//
//  WebExtensionPageViewController.swift
//  BrownBear
//
//  Renders an extension's popup (`action.default_popup`) in a real WKWebView over the
//  chrome-extension:// scheme — the "extensions have UI, like Orion/Gear" capability (Module 6
//  Phase 3). The chrome.* bridge itself lives in WebExtensionPageSession (shared with the tab-hosted
//  options page); this controller is just the sheet/full-screen host: it owns the web view, surfaces
//  load failures instead of a blank card, and tears the session down on dismiss.
//

import UIKit
import WebKit

@MainActor
final class WebExtensionPageViewController: UIViewController {

    /// Kept as an alias so existing call sites (`kind: .popup` / `.options`) read unchanged.
    typealias Kind = WebExtensionPageSession.Kind

    private let session: WebExtensionPageSession
    private var webView: WKWebView?
    /// True when this page is hosted in a floating popover (the toolbar action popup) rather than a sheet,
    /// so the backdrop is glass and the content size hugs the popup's own HTML dimensions.
    private var isPopover = false

    init(ext: WebExtension,
         kind: Kind,
         path: String? = nil,
         store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         storage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage,
         runtime: WebExtensionRuntime = BrownBearServices.shared.webExtensionRuntime) {
        self.session = WebExtensionPageSession(ext: ext, kind: kind, path: path,
                                               store: store, storage: storage, runtime: runtime)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // A floating popup floats over the page on frosted glass (matching the Site Shields panel); a
        // sheet-hosted page (options) keeps the solid surface.
        if isPopover {
            GlassBackground.install(in: view)
        } else {
            view.backgroundColor = BrownBearTheme.Palette.background
        }
        title = session.ext.displayName
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))

        guard session.pageURL != nil else {
            showMissing()
            return
        }
        Task { await build() }
    }

    @objc private func close() { dismiss(animated: true) }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Stop receiving browser-pushed events and disconnect this page's ports once it's gone.
        session.invalidate()
    }

    // MARK: - Build

    private func build() async {
        guard let url = session.pageURL else {
            showMissing()
            return
        }
        let configuration = await session.makeConfiguration()
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        // Extension pages run browser-detection that keys off UA tokens — Bitwarden's getDevice needs
        // " Chrome/" (Chrome build) or " Firefox/" (Firefox build); the default WKWebView UA carries
        // neither, so its DeviceType resolved to undefined and `device.toString()` threw, crashing the
        // Angular popup before it rendered (the "stuck on the loading spinner" symptom). Present a UA
        // matching the extension's build so detection lands on the right ChromeExtension/FirefoxExtension.
        let firefoxBuild = session.ext.scheme == WebExtensionSchemeHandler.firefoxScheme
        webView.customUserAgent = firefoxBuild
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X; rv:121.0) Gecko/121.0 Firefox/121.0"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Chrome/121.0.0.0 Mobile/15E148 Safari/604.1"
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        // Clear over the glass so any transparent popup areas reveal the frosted backdrop; opaque popups
        // simply paint their own body. A sheet keeps the solid surface behind it.
        webView.backgroundColor = isPopover ? .clear : BrownBearTheme.Palette.background
        webView.navigationDelegate = self   // surface load failures instead of a blank sheet
        webView.uiDelegate = self            // route window.open() (e.g. ScriptCat's Options button) to a real tab
        view.addSubview(webView)
        self.webView = webView
        session.bind(to: webView)
        webView.load(URLRequest(url: url))
    }

    // MARK: - Missing / failed page

    private func showMissing() {
        showCenteredMessage("This extension has no \(session.kind.title.lowercased()) page.")
    }

    /// Replace the (possibly blank) web view with a centered message — used for a missing page and for
    /// a load failure, so the user sees WHY a page is empty instead of a blank sheet.
    private func showCenteredMessage(_ text: String) {
        webView?.isHidden = true
        view.viewWithTag(Self.messageLabelTag)?.removeFromSuperview()
        let label = UILabel()
        label.tag = Self.messageLabelTag
        label.text = text
        label.textColor = BrownBearTheme.Palette.textSecondary
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    private static let messageLabelTag = 0xBBEE

    // MARK: - Presentation

    /// Fixed popup width (most extension popups declare ~300–400pt) and the height bounds the popover
    /// hugs to once its HTML has laid out. The initial height is a sensible guess until `didFinish`.
    private static let popoverWidth: CGFloat = 360
    private static let popoverInitialHeight: CGFloat = 420
    private static let popoverMinHeight: CGFloat = 160
    private static let popoverMaxHeight: CGFloat = 560

    /// Present as a floating glassy popover anchored to `sourceView` (the toolbar action button) instead
    /// of a sheet, so the popup hovers over the page like Chrome/Safari — the page stays visible around
    /// it. Width is fixed; the height grows to the popup's own content after it loads.
    func makePopover(sourceView: UIView, sourceRect: CGRect) -> UIViewController {
        isPopover = true
        modalPresentationStyle = .popover
        preferredContentSize = CGSize(width: Self.popoverWidth, height: Self.popoverInitialHeight)
        if let popover = popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect
            // The toolbar sits at the bottom, so the popover rises UP over the page (arrow down at the
            // button); allow .up as a fallback if UIKit can't fit it above.
            popover.permittedArrowDirections = [.down, .up]
            popover.delegate = self
            popover.backgroundColor = .clear   // let the glass backdrop show instead of an opaque frame
        }
        return self
    }

    /// Shrink/grow the popover to the popup's own rendered height (clamped), so a short popup isn't a tall
    /// empty card and a long one scrolls within a sensible cap. No-op for the sheet-hosted options page.
    private func sizePopoverToContent() {
        guard isPopover, let webView else { return }
        let measure = "(function(){var d=document.documentElement,b=document.body;" +
            "return Math.max(d?d.scrollHeight:0,b?b.scrollHeight:0,b?b.offsetHeight:0);})()"
        // The completion is a non-isolated ObjC block (called on the main thread); hop to the main actor
        // before touching preferredContentSize so it's safe under strict concurrency checking.
        BBEvaluateJavaScriptForResult(webView, measure, .page) { result, _ in
            guard let height = (result as? NSNumber)?.doubleValue, height > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let clamped = min(max(CGFloat(height), Self.popoverMinHeight), Self.popoverMaxHeight)
                guard abs(clamped - self.preferredContentSize.height) > 1 else { return }
                // Setting preferredContentSize animates the popover resize for free.
                self.preferredContentSize = CGSize(width: Self.popoverWidth, height: clamped)
            }
        }
    }

    /// Wrap in a navigation controller with a sheet presentation (medium/large detents).
    func wrappedForPresentation() -> UIViewController {
        let nav = UINavigationController(rootViewController: self)
        nav.navigationBar.prefersLargeTitles = false
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        return nav
    }
}

// MARK: - WKNavigationDelegate (surface load failures instead of a blank sheet)

extension WebExtensionPageViewController: WKNavigationDelegate {
    // NOTE: the selector MUST be `didFailProvisionalNavigation` — the prior `didFailProvisional:` was a typo
    // WebKit never calls, so the most common popup/options failure (the page HTML 404ing through the scheme
    // handler — a PROVISIONAL nav failure) showed neither this message NOR a log. That made a missing/blank
    // popup completely undiagnosable.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportPageLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportPageLoadFailure(error)
    }

    /// A 200-OK extension page whose top-level script / ES-module graph silently fails to run (e.g. a
    /// `<script type="module">` that won't load over the custom scheme — the suspected uBO Lite popup/
    /// options blank) fires NO error: it just renders blank. didFail/didFailProvisionalNavigation never
    /// fire. So probe shortly after load and, if the body is empty or stuck in a loading state, log it —
    /// turning an invisible blank dead-end into a diagnosable Logs line.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let extID = session.ext.id, kind = session.kind.title
        // Size the popover to the popup now, and again after a beat for popups that fill asynchronously
        // (e.g. once their background worker replies).
        sizePopoverToContent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else { return }
            self.sizePopoverToContent()
            // Probe the rendered body AND the page-module bundle's run report (globalThis.__bbPageBundle,
            // set by brownbear-esm-page-bundler.js). The body state alone can't tell apart "a module
            // threw" from "the bundle ran but the page is still waiting on the background worker" — the
            // run report (entries ran / total + the first failing module) disambiguates them, so the Logs
            // tab names the exact cause instead of a bare "still-loading".
            let probe = """
            (function () {
              var b = document.body;
              var state = !b ? 'no-body'
                : ((b.childElementCount === 0 && (b.textContent || '').trim().length === 0) ? 'blank'
                   : (/\\b(loading|busy|spinner)\\b/i.test(b.className || '') ? 'still-loading' : 'ok'));
              var out = { state: state };
              var rep = (typeof globalThis !== 'undefined') ? globalThis.__bbPageBundle : null;
              if (rep) {
                out.total = rep.total; out.ran = rep.ran;
                out.errors = (rep.errors || []).slice(0, 4).map(function (e) {
                  return { entry: String(e.entry || ''), message: String(e.message || '').slice(0, 300) };
                });
              }
              return JSON.stringify(out);
            })()
            """
            BBEvaluateJavaScriptForResult(webView, probe, .page) { result, _ in
                guard let raw = result as? String, let data = raw.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let state = obj["state"] as? String else { return }
                let errors = (obj["errors"] as? [[String: Any]]) ?? []
                // A fully-rendered page with every module entry run and no errors is healthy — say nothing.
                guard state != "ok" || !errors.isEmpty else { return }
                Task { await BrownBearServices.shared.webExtensionRuntime.logFromPage(
                    extensionID: extID, level: "warn",
                    message: Self.pageDiagnostic(kind: kind, state: state,
                                                 ran: obj["ran"] as? Int, total: obj["total"] as? Int,
                                                 errors: errors)) }
            }
        }
    }

    /// Build the Logs-tab line for a popup/options page that didn't render cleanly. Pulled out (and
    /// `internal`) so the body-state → message mapping is unit-testable without a live web view. The
    /// run report (`ran`/`total` + first failing module) is what tells apart a module that threw from a
    /// bundle that ran but is still waiting on the worker.
    nonisolated static func pageDiagnostic(kind: String, state: String, ran: Int?, total: Int?,
                                           errors: [[String: Any]]) -> String {
        var message = "\(kind) page rendered '\(state)'"
        if let total {
            message += " — page module bundle ran \(ran ?? 0)/\(total) entries"
        }
        if let first = errors.first, let entry = first["entry"] as? String, !entry.isEmpty {
            let detail = (first["message"] as? String) ?? ""
            message += "; first failing module \(entry): \(detail)"
        } else if let ran, let total, ran >= total, state != "ok" {
            // Every entry ran yet the page is still in a loading state → its script is waiting on
            // something (typically a background-worker round-trip), not a module that failed to load.
            message += " (all modules ran — the page is waiting on the background worker)"
        } else if total == nil {
            message += " — its script/module likely failed to run"
        }
        return message
    }

    /// Show the failure in the sheet AND forward it to the Logs tab (it persists after the sheet closes,
    /// so a transient blank popup is still diagnosable).
    private func reportPageLoadFailure(_ error: Error) {
        showCenteredMessage("Couldn’t open this \(session.kind.title.lowercased()) page.\n\(error.localizedDescription)")
        let extID = session.ext.id, kind = session.kind.title
        Task { await BrownBearServices.shared.webExtensionRuntime
            .logFromPage(extensionID: extID, level: "error",
                         message: "\(kind) page failed to load: \(error.localizedDescription)") }
    }
}

// MARK: - WKUIDelegate (window.open from an extension popup → a real tab)

extension WebExtensionPageViewController: WKUIDelegate {
    /// An extension popup opens its own pages with `window.open("/src/options.html", "_blank")` (ScriptCat's
    /// Options & new-script buttons) rather than chrome.runtime.openOptionsPage. WKWebView routes that
    /// through here; with no uiDelegate it returns nil and the click is silently dropped — the dead-button
    /// symptom. There is no child web view to hand back on iOS, so we open the target ourselves and return
    /// nil: an extension-scheme URL becomes a real extension tab (scheme handler + chrome.* bridge); an
    /// http(s) target opens as a normal browser tab. The popup sheet is dismissed so the new tab is visible.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let host = BrownBearServices.shared.webExtensionRuntime.host
        if WebExtensionSchemeHandler.isExtensionScheme(url.scheme) {
            // Resolve against THIS popup's extension origin (a popup only opens its own pages); the path is
            // what openExtensionPageTab needs. Restrict to the popup's own extension as a trust boundary.
            let path = url.path.isEmpty ? "/" : url.path
            _ = host?.webExtOpenExtensionPage(extensionID: session.ext.id, path: path)
            dismiss(animated: true)
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            _ = host?.webExtCreateTab(url: url.absoluteString, active: true)
            dismiss(animated: true)
        }
        return nil
    }
}

// MARK: - UIPopoverPresentationControllerDelegate (stay a true popover on iPhone)

extension WebExtensionPageViewController: UIPopoverPresentationControllerDelegate {
    /// Keep the action popup an arrow-anchored popover on compact widths too, instead of UIKit's default
    /// adaptive full-screen sheet — the whole point is that it floats over the page.
    nonisolated func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

/// Presents a UIKit view controller from SwiftUI by walking to the top-most presented controller of
/// the active window — used to surface an extension's popup over the dashboard.
enum TopViewControllerPresenter {
    @MainActor
    static func present(_ controller: UIViewController) {
        guard let top = topMost() else { return }
        top.present(controller, animated: true)
    }

    /// Dismiss the top-most presented controller (e.g. an extension popup sheet) so a newly opened tab
    /// behind it is visible. No-op when nothing is presented.
    @MainActor
    static func dismissTopPresented() {
        guard let window = keyWindow(), let root = window.rootViewController,
              root.presentedViewController != nil else { return }
        root.dismiss(animated: true)
    }

    @MainActor
    private static func topMost() -> UIViewController? {
        guard var top = keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
        return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    }
}
