//
//  WebExtensionWebAuthFlow.swift
//  BrownBear
//
//  chrome.identity.launchWebAuthFlow — present an interactive OAuth / web-auth flow in a system auth
//  session and resolve with the redirect URL the provider lands on. Chrome's contract: the flow ends when
//  the web content navigates to `https://<extension-id>.chromiumapp.org/...` (the value getRedirectURL
//  returns, which the extension registers as its OAuth redirect URI). Matching that HTTPS redirect needs
//  iOS 17.4's `ASWebAuthenticationSession.Callback.https`; below that we fail with a clear error rather
//  than hang. The auth URL is untrusted extension input — it must be a real http(s) URL (fail closed).
//
//  The presentation/auth half is inherently device-gated (a system UI + network flow); the request parsing
//  + redirect-host derivation is pure and unit-tested (WebExtensionWebAuthFlowTests).
//

import AuthenticationServices
import Foundation
import UIKit

enum WebAuthFlowError: Error, Sendable {
    case badURL
    case interactionRequired   // interactive:false but we can't complete a flow without UI on iOS
    case unsupportedOS
    case noPresentationAnchor
    case cancelled
    case failed(String)

    /// A human-readable message surfaced to the extension (chrome.runtime.lastError).
    var message: String {
        switch self {
        case .badURL: return "launchWebAuthFlow requires a valid http(s) url."
        case .interactionRequired: return "User interaction required."
        case .unsupportedOS: return "launchWebAuthFlow requires iOS 17.4 or later."
        case .noPresentationAnchor: return "No window is available to present the auth flow."
        case .cancelled: return "The user did not approve access."
        case .failed(let detail): return detail
        }
    }
}

/// The validated, pure form of a launchWebAuthFlow request — parsed/derived without any UI so it's unit-
/// testable. `callbackHost` is the chromiumapp.org host derived from the extension id, so a provider
/// redirect to `https://<id>.chromiumapp.org/...` ends the flow (matching getRedirectURL).
struct WebAuthFlowRequest: Equatable {
    let authURL: URL
    let callbackHost: String
    let interactive: Bool

    static func parse(args: [String: Any], extensionID: String) -> WebAuthFlowRequest? {
        guard let urlString = args["url"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              (url.host?.isEmpty == false), !extensionID.isEmpty else { return nil }
        let interactive = (args["interactive"] as? Bool) ?? false
        return WebAuthFlowRequest(authURL: url, callbackHost: "\(extensionID).chromiumapp.org",
                                  interactive: interactive)
    }
}

/// Presents an ASWebAuthenticationSession and answers its anchor query. Intentionally NOT `@MainActor` (the
/// presentation-context protocol requirement is non-isolated; `presentationAnchor` is called by the system
/// on the main thread, where the anchor — an immutable `let` — is read). The UI-touching entry points are
/// `@MainActor` statics below.
final class WebExtensionWebAuthFlow: NSObject, ASWebAuthenticationPresentationContextProviding {

    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    /// In-flight flows + their continuations, keyed by flow identity. Holding the flow here keeps it (and
    /// its session) alive across the system UI — the session's `presentationContextProvider` is weak, so
    /// nothing else would. `settle` removes the entry (the atomic settle-once gate) and resumes. Confined
    /// to the main actor, so all access is serialized.
    private struct PendingFlow {
        let flow: WebExtensionWebAuthFlow
        let continuation: CheckedContinuation<Result<URL, WebAuthFlowError>, Never>
    }
    @MainActor private static var pending: [ObjectIdentifier: PendingFlow] = [:]

    private init(anchor: ASPresentationAnchor) { self.anchor = anchor; super.init() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    /// Run the flow for an already-validated request and return the redirect URL, or a typed error.
    @MainActor
    static func launch(_ request: WebAuthFlowRequest) async -> Result<URL, WebAuthFlowError> {
        // Chrome's interactive:false completes a flow only if no UI is needed; iOS can't do that silently,
        // so report interaction-required (extensions then retry with interactive:true).
        guard request.interactive else { return .failure(.interactionRequired) }
        guard #available(iOS 17.4, *) else { return .failure(.unsupportedOS) }
        guard let anchor = activeWindow() else { return .failure(.noPresentationAnchor) }
        return await withCheckedContinuation { continuation in
            WebExtensionWebAuthFlow(anchor: anchor).begin(request: request, continuation: continuation)
        }
    }

    /// Resume the continuation for `id` exactly once (removeValue is the settle-once gate) and drop the
    /// strong references that kept the flow + its session alive.
    @MainActor
    private static func settle(_ id: ObjectIdentifier, _ outcome: Result<URL, WebAuthFlowError>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.flow.session = nil
        entry.continuation.resume(returning: outcome)
    }

    @available(iOS 17.4, *)
    @MainActor
    private func begin(request: WebAuthFlowRequest,
                       continuation: CheckedContinuation<Result<URL, WebAuthFlowError>, Never>) {
        let id = ObjectIdentifier(self)
        Self.pending[id] = PendingFlow(flow: self, continuation: continuation)
        let callback = ASWebAuthenticationSession.Callback.https(host: request.callbackHost, path: "/")
        // The system completion handler may arrive off the main thread, so it captures ONLY Sendable
        // values (the flow id + the computed Sendable outcome) and hops to the main actor to settle —
        // never a non-Sendable capture inside this (possibly @Sendable) block.
        let session = ASWebAuthenticationSession(url: request.authURL, callback: callback) { url, error in
            let outcome: Result<URL, WebAuthFlowError>
            if let url {
                outcome = .success(url)
            } else if let authError = error as? ASWebAuthenticationSessionError,
                      authError.code == .canceledLogin {
                outcome = .failure(.cancelled)
            } else {
                outcome = .failure(.failed(error?.localizedDescription ?? "Auth failed."))
            }
            Task { @MainActor in WebExtensionWebAuthFlow.settle(id, outcome) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() { Self.settle(id, .failure(.failed("Couldn't start the auth session."))) }
    }

    /// The dispatch entry the __bb_identity bridge calls. Returns the JSON-shaped result the JS side resolves
    /// (`responseUrl`) or rejects (`error`) on.
    @MainActor
    static func dispatch(method: String, args: [String: Any], extensionID: String) async -> [String: Any] {
        switch method {
        case "launchWebAuthFlow":
            guard let request = WebAuthFlowRequest.parse(args: args, extensionID: extensionID) else {
                return ["error": WebAuthFlowError.badURL.message]
            }
            switch await launch(request) {
            case .success(let url): return ["responseUrl": url.absoluteString]
            case .failure(let error): return ["error": error.message]
            }
        default:
            return ["error": "Unsupported identity method."]
        }
    }

    /// The key window to anchor the auth sheet on (mirrors WebExtensionPermissionPrompt). Fail closed: nil
    /// when there's no presentable window.
    @MainActor
    private static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) { return key }
        return scenes.first?.windows.first
    }
}
