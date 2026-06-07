//
//  WebExtensionPermissionPrompt.swift
//  BrownBear
//
//  The user-consent gate for chrome.permissions.request. Chrome shows a permission dialog before
//  granting an OPTIONAL permission a script asks for at runtime; BrownBear used to auto-grant, which
//  let an extension silently widen its own reach. This presents a simple allow/deny alert (on the
//  topmost view controller, via TopViewControllerPresenter, so it works whether the request comes from
//  a content script, a popup, or a background worker) and only records the grant when the user allows.
//
//  Fail closed: if there is no view controller to present on, the request is DENIED rather than
//  silently granted. An empty request (nothing new to grant) is allowed without prompting — there is
//  no new capability to consent to, matching Chrome's \"already-held permissions resolve true\" behavior.
//

import UIKit

enum WebExtensionPermissionPrompt {

    /// Ask the user whether `extensionName` may be granted the optional permissions/origins in
    /// `toGrant`. Returns true to allow (the caller then records the grant). Presented on the topmost
    /// view controller so it surfaces over the browser, the dashboard, or an open popup alike.
    @MainActor
    static func request(extensionName: String,
                        toGrant: WebExtensionManagementInfo.PermissionSet) async -> Bool {
        // Nothing new to consent to — already held. Allow without bothering the user (Chrome parity).
        if toGrant.isEmpty { return true }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
                ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
                  window.rootViewController != nil else {
                continuation.resume(returning: false)   // no UI to consent on — fail closed
                return
            }

            let alert = UIAlertController(title: "Allow new permissions?",
                                          message: Self.message(extensionName: extensionName, toGrant: toGrant),
                                          preferredStyle: .alert)
            var settled = false
            func finish(_ allowed: Bool) {
                guard !settled else { return }
                settled = true
                continuation.resume(returning: allowed)
            }
            alert.addAction(UIAlertAction(title: "Deny", style: .cancel) { _ in finish(false) })
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in finish(true) })

            TopViewControllerPresenter.present(alert)
        }
    }

    /// Human-readable list of what the extension is asking for, capped so a script can't blow up the
    /// alert with hundreds of origins.
    private static func message(extensionName: String,
                                toGrant: WebExtensionManagementInfo.PermissionSet) -> String {
        var lines: [String] = []
        let perms = toGrant.permissions.sorted()
        if !perms.isEmpty { lines.append("Permissions: " + perms.joined(separator: ", ")) }
        let origins = toGrant.origins.sorted()
        if !origins.isEmpty {
            let shown = origins.prefix(8).joined(separator: ", ")
            let extra = origins.count > 8 ? " (+\(origins.count - 8) more)" : ""
            lines.append("Site access: " + shown + extra)
        }
        let detail = lines.isEmpty ? "additional access" : lines.joined(separator: "\n")
        return "“\(extensionName)” is requesting:\n\n\(detail)\n\nAllow grants these to the extension. "
            + "Deny keeps them off."
    }
}
