//
//  WebExtensionPageViewController.swift
//  BrownBear
//
//  Renders an extension's popup (`action.default_popup`) or options page in a real WKWebView over
//  the chrome-extension:// scheme — the "extensions have UI, like Orion/Gear" capability (Module 6
//  Phase 3). The page gets a synchronous chrome.* surface: native bakes the extension's identity
//  (token + manifest + i18n) into the page at document-start, then brownbear-webext-page.js builds
//  chrome.storage/runtime/i18n/extension around the bridge. storage.onChanged is pushed in live.
//

import UIKit
import WebKit

@MainActor
final class WebExtensionPageViewController: UIViewController {

    enum Kind {
        case popup
        case options

        var title: String {
            switch self {
            case .popup: return "Popup"
            case .options: return "Options"
            }
        }
    }

    private let ext: WebExtension
    private let kind: Kind
    private let store: WebExtensionStore
    private let storage: WebExtensionStorage
    private let runtime: WebExtensionRuntime

    private let router: WebExtensionMessageRouter
    private let schemeHandler: WebExtensionSchemeHandler
    private let contentWorld = WKContentWorld.page

    private var webView: WKWebView?
    private var storageObserver: NSObjectProtocol?
    private var cookieObserver: NSObjectProtocol?
    private var notificationObserver: NSObjectProtocol?
    /// This page's session token, retained so its open chrome.runtime ports can be torn down on dismiss.
    private var pageToken: String?

    init(ext: WebExtension,
         kind: Kind,
         store: WebExtensionStore = BrownBearServices.shared.webExtensionStore,
         storage: WebExtensionStorage = BrownBearServices.shared.webExtensionStorage,
         runtime: WebExtensionRuntime = BrownBearServices.shared.webExtensionRuntime) {
        self.ext = ext
        self.kind = kind
        self.store = store
        self.storage = storage
        self.runtime = runtime
        self.router = WebExtensionMessageRouter(store: store, storage: storage, runtime: runtime,
                                                contentWorld: contentWorld)
        self.schemeHandler = WebExtensionSchemeHandler(extensionID: ext.id, store: store)
        super.init(nibName: nil, bundle: nil)
        // The popup runs its own router instance, so give it the same chrome.tabs + chrome.cookies
        // bridges the runtime holds (set when the browser VC loaded), or popups couldn't reach them.
        self.router.host = runtime.host
        self.router.cookieHost = runtime.cookieHost
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        if let cookieObserver { NotificationCenter.default.removeObserver(cookieObserver) }
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
    }

    // MARK: - The page path

    /// The manifest-declared file for this kind, or nil if the extension doesn't define one.
    var pagePath: String? {
        switch kind {
        case .popup: return ext.manifest?.action?.defaultPopup
        case .options: return ext.manifest?.optionsPage
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BrownBearTheme.Palette.background
        title = ext.displayName
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))

        guard let path = pagePath else {
            showMissing()
            return
        }
        Task { await build(path: path) }
    }

    @objc private func close() { dismiss(animated: true) }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Stop receiving browser-pushed events once the page is gone (the runtime holds receivers
        // weakly, so this just prunes promptly rather than waiting for the next fan-out to skip a dead box).
        runtime.unregisterEventReceiver(self)
        // Tear down any chrome.runtime ports this popup/options page opened so the worker's onDisconnect
        // fires rather than stranding the channel against a dismissed web view.
        if let pageToken {
            runtime.portHub.disconnectClientPorts(tokens: [pageToken])
        }
    }

    // MARK: - Build

    private func build(path: String) async {
        let messages = await loadMessages()
        let token = router.makePageSession(for: ext.id)
        self.pageToken = token

        let bootstrapData: [String: Any] = [
            "token": token,
            "extensionId": ext.id,
            "manifestJSON": ext.manifestJSON,
            "baseURL": ext.baseURLString,
            "messages": messages
        ]
        let dataJSON = Self.jsonString(bootstrapData)

        let controller = WKUserContentController()
        controller.addScriptMessageHandler(router, contentWorld: contentWorld, name: WebExtensionMessageRouter.handlerName)
        controller.addUserScript(WKUserScript(source: "window.__bbExtPage = \(dataJSON);",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.pageRuntimeSource,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebExtensionSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = BrownBearTheme.Palette.background
        webView.navigationDelegate = self   // surface load failures instead of a blank sheet
        view.addSubview(webView)
        self.webView = webView
        // Bind the page session to this web view so the runtime can push chrome.runtime.connect port
        // traffic INTO this popup/options page (the session was minted before the web view existed).
        router.attachPageWebView(token: token, webView: webView)

        observeStorageChanges()
        // Receive browser-pushed chrome.tabs.* / chrome.webNavigation.* events for this extension.
        runtime.registerEventReceiver(self)

        guard let url = URL(string: "\(WebExtensionSchemeHandler.scheme)://\(ext.id)/\(path)") else {
            showMissing()
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Load the default-locale messages.json (flattened) for chrome.i18n, mirroring the content side.
    private func loadMessages() async -> [String: String] {
        guard let locale = ext.manifest?.defaultLocale,
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

    // MARK: - storage.onChanged push

    private func observeStorageChanges() {
        storageObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionStorageDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleStorageChange(note) }
        }
        cookieObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionCookieDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleCookieChange(note) }
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .brownBearExtensionNotificationEvent, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleNotificationEvent(note) }
        }
    }

    /// Deliver a chrome.notifications event to an open popup/options page's listeners.
    private func handleNotificationEvent(_ note: Notification) {
        guard let info = note.userInfo,
              info["extensionID"] as? String == ext.id,
              let kind = info["kind"] as? String,
              let notificationID = info["notificationID"] as? String,
              let webView else { return }
        let idJSON = Self.jsonString(notificationID)
        let js: String
        switch kind {
        case "clicked":
            js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchNotificationClicked(\(idJSON));"
        case "closed":
            let byUser = (info["byUser"] as? Bool) ?? false
            js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchNotificationClosed(\(idJSON), \(byUser));"
        case "buttonClicked":
            let idx = (info["buttonIndex"] as? Int) ?? 0
            js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchNotificationButtonClicked(\(idJSON), \(idx));"
        default:
            return
        }
        BBEvaluateJavaScript(webView, js, contentWorld)   // ObjC shim — no Swift WebKit overlay (iOS 16.4).
    }

    /// Push a cookie change into an open popup/options page's chrome.cookies.onChanged. Double-encoded
    /// (a JSON string the page JS will _JSON.parse), matching dispatchStorageChanged.
    private func handleCookieChange(_ note: Notification) {
        guard let change = note.userInfo?["change"] as? [String: Any], let webView else { return }
        let js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchCookieChanged("
            + "\(Self.jsonString(Self.jsonString(change))));"
        BBEvaluateJavaScript(webView, js, contentWorld)
    }

    private func handleStorageChange(_ note: Notification) {
        guard let info = note.userInfo,
              info["extensionID"] as? String == ext.id,
              let area = info["area"] as? String,
              let changes = info["changes"] as? [String: [String: String]],
              let webView else { return }
        let changesJSON = Self.jsonString(changes)
        let js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchStorageChanged(\(Self.jsonString(area)), \(Self.jsonString(changesJSON)));"
        // Via the ObjC shim so we don't link the Swift WebKit overlay (see BBWebKitBridge.h).
        BBEvaluateJavaScript(webView, js, contentWorld)
    }

    // MARK: - Missing page

    private func showMissing() {
        showCenteredMessage("This extension has no \(kind.title.lowercased()) page.")
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

    /// Wrap as a full-screen page (not a sheet) — for the options page opened from the "•••" menu or
    /// chrome.runtime.openOptionsPage, which should read as a real, keepable page rather than a card.
    /// The nav controller carries the Done button to dismiss.
    func wrappedAsFullPage() -> UIViewController {
        let nav = UINavigationController(rootViewController: self)
        nav.navigationBar.prefersLargeTitles = false
        nav.modalPresentationStyle = .fullScreen
        return nav
    }

    // MARK: - Helpers

    private static func jsonString(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }

    private static let pageRuntimeSource: String = {
        guard let url = Bundle.main.url(forResource: "brownbear-webext-page", withExtension: "js", subdirectory: nil)
                ?? Bundle.main.url(forResource: "brownbear-webext-page", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "/* brownbear-webext-page.js missing */"
        }
        return source
    }()
}

extension WebExtensionPageViewController: WebExtensionEventReceiver {
    var receiverExtensionID: String { ext.id }
    var receiverPermissions: Set<String> { Set(ext.manifest?.permissions ?? []) }

    /// Deliver a browser-pushed chrome.tabs/webNavigation event into this page's chrome.* surface.
    func dispatchExtEvent(name: String, argsJSON: String) {
        guard let webView else { return }
        let js = "window.__brownbearExtPage && window.__brownbearExtPage.dispatchExtEvent("
            + "\(Self.jsonString(name)), \(Self.jsonString(argsJSON)));"
        BBEvaluateJavaScript(webView, js, contentWorld)   // ObjC shim — no Swift WebKit overlay (iOS 16.4).
    }
}

/// Presents a UIKit view controller from SwiftUI by walking to the top-most presented controller of
/// the active window — used to surface an extension's popup/options page over the dashboard.
enum TopViewControllerPresenter {
    @MainActor
    static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}

// MARK: - WKNavigationDelegate (surface load failures instead of a blank sheet)

extension WebExtensionPageViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisional navigation: WKNavigation!, withError error: Error) {
        showCenteredMessage("Couldn’t open this \(kind.title.lowercased()) page.\n\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showCenteredMessage("Couldn’t open this \(kind.title.lowercased()) page.\n\(error.localizedDescription)")
    }
}
