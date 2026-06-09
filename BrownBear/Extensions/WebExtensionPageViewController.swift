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

    init(ext: WebExtension,
         kind: Kind,
         store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         storage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage,
         runtime: WebExtensionRuntime = BrownBearServices.shared.webExtensionRuntime) {
        self.session = WebExtensionPageSession(ext: ext, kind: kind, store: store, storage: storage, runtime: runtime)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
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
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = BrownBearTheme.Palette.background
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
        if url.scheme == WebExtensionSchemeHandler.scheme {
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
