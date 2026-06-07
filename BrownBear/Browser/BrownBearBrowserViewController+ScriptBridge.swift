//
//  BrownBearBrowserViewController+ScriptBridge.swift
//  BrownBear
//
//  The browser's implementation of the host-reaching userscript GM apis added to ScriptBridgeHost:
//  GM_cookie (over the shared WKHTTPCookieStore, reusing the chrome.cookies matching the VC already
//  has in +Cookies), GM_download (DownloadManager + an optional share sheet), and the GM_notification
//  in-app fallback toast. The router has ALREADY @connect-gated the cookie host / download url before
//  any of these run — this file does the UI/jar plumbing only. Split into its own file so the main VC
//  stays under the file_length limit.
//

import UIKit
import WebKit

extension BrownBearBrowserViewController {

    /// GM_notification in-app fallback: a brief alert when the OS suppressed the banner (UN auth
    /// denied), so the notification isn't silently lost. Best-effort, non-blocking.
    func bridgeShowNotificationFallback(title: String, body: String) {
        let text = body.isEmpty ? title : "\(title): \(body)"
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        TopViewControllerPresenter.present(alert)
    }

    /// GM.cookie.list — delegate to the chrome.cookies getAll the VC already implements (store id nil
    /// resolves to the default "0" jar). The router already @connect-gated the host.
    func bridgeListCookies(filter: [String: Any]) async -> [[String: Any]] {
        await webExtGetAllCookies(filter: filter, storeId: nil)
    }

    /// GM.cookie.set — create/overwrite a cookie from chrome setDetails; returns the stored cookie.
    func bridgeSetCookie(details: [String: Any]) async -> [String: Any]? {
        await webExtSetCookie(details: details, storeId: nil)
    }

    /// GM.cookie.delete — delete the cookie matching name+url; returns the removal details, or nil.
    func bridgeDeleteCookie(url: String, name: String) async -> [String: Any]? {
        await webExtRemoveCookie(url: url, name: name, storeId: nil)
    }

    /// GM_download — write already-fetched bytes into the Downloads list and (optionally) present a
    /// share/save sheet. Returns the on-disk URL, or nil on write failure.
    func bridgeSaveDownload(data: Data, suggestedName: String, presentSheet: Bool) async -> URL? {
        guard let url = DownloadManager.shared.registerLocalDownload(data: data,
                                                                     suggestedName: suggestedName) else {
            return nil
        }
        presentDownloadStartedToast()
        if presentSheet {
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            TopViewControllerPresenter.present(share)
        }
        return url
    }
}
