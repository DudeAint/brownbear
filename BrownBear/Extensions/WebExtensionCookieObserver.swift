//
//  WebExtensionCookieObserver.swift
//  BrownBear
//
//  Bridges `WKHTTPCookieStore` change notifications to `chrome.cookies.onChanged`. WebKit's observer
//  callback (`cookiesDidChange(in:)`) carries NO diff — it just says "something changed" — so we keep
//  the last snapshot and, on each tick, re-read and diff to synthesize chrome's per-cookie
//  `{ removed, cookie, cause }` change records. Posts `.brownBearExtensionCookieDidChange`, which
//  WebExtensionRuntime fans out to every background worker and WebExtensionPageViewController fans
//  out to every open extension page (mirroring the storage.onChanged pipeline).
//
//  Snapshotting on a coalesced main-actor flow keeps the diff coherent; the cost is one extra cookie
//  read per change, cheap for the modest cookie counts a single device holds.
//

import Foundation
import WebKit

@MainActor
final class WebExtensionCookieObserver: NSObject, WKHTTPCookieStoreObserver {

    /// A stable identity for one cookie so we can diff snapshots across change ticks.
    private struct Key: Hashable { let name: String; let domain: String; let path: String }

    private let store: WKHTTPCookieStore
    private var snapshot: [Key: HTTPCookie] = [:]
    private var refreshing = false
    private var pending = false
    private var started = false

    init(store: WKHTTPCookieStore) {
        self.store = store
        super.init()
    }

    /// Begin observing. Takes the initial snapshot first so the first real change diffs against the
    /// existing jar rather than reporting every already-present cookie as freshly added.
    func start() {
        guard !started else { return }
        started = true
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            Task { @MainActor in
                self.snapshot = Self.index(cookies)
                self.store.add(self)
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        store.remove(self)
    }

    // MARK: - WKHTTPCookieStoreObserver

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    // MARK: - Diff + emit

    /// Re-read the jar and emit a change record for every cookie that appeared, disappeared, or had
    /// its value overwritten since the last snapshot. Coalesces overlapping ticks (WebKit can fire
    /// several in a burst).
    private func refresh() {
        if refreshing { pending = true; return }
        refreshing = true
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            Task { @MainActor in
                self.applyDiff(newCookies: cookies)
                self.refreshing = false
                if self.pending { self.pending = false; self.refresh() }
            }
        }
    }

    private func applyDiff(newCookies: [HTTPCookie]) {
        let next = Self.index(newCookies)
        for (key, old) in snapshot {
            if let current = next[key] {
                if Self.attributesDiffer(old, current) {
                    // Any observable change (value OR secure/httpOnly/sameSite/expiry) is a remove
                    // ("overwrite") then an add ("explicit"); Chrome fires onChanged for these too.
                    post(cookie: old, removed: true, cause: "overwrite")
                    post(cookie: current, removed: false, cause: "explicit")
                }
            } else {
                post(cookie: old, removed: true, cause: "explicit")
            }
        }
        for (key, current) in next where snapshot[key] == nil {
            post(cookie: current, removed: false, cause: "explicit")
        }
        snapshot = next
    }

    private func post(cookie: HTTPCookie, removed: Bool, cause: String) {
        let record: [String: Any] = [
            "removed": removed,
            "cause": cause,
            "cookie": WebExtensionCookieMapper.chromeCookie(from: cookie)
        ]
        NotificationCenter.default.post(name: .brownBearExtensionCookieDidChange,
                                        object: nil, userInfo: ["change": record])
    }

    /// Whether two cookies sharing the same (name, domain, path) Key differ in any attribute
    /// chrome.cookies.onChanged should report. Path/name/domain are part of the Key (a change there is
    /// already a remove+add), so this compares value, secure, httpOnly, sameSite, and expiry. Pure +
    /// unit-tested — the old code only compared `value`, so secure/expiry/etc. flips fired nothing.
    static func attributesDiffer(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        a.value != b.value
            || a.isSecure != b.isSecure
            || a.isHTTPOnly != b.isHTTPOnly
            || a.expiresDate != b.expiresDate
            || a.sameSitePolicy != b.sameSitePolicy
    }

    private static func index(_ cookies: [HTTPCookie]) -> [Key: HTTPCookie] {
        var map: [Key: HTTPCookie] = [:]
        for cookie in cookies {
            map[Key(name: cookie.name, domain: cookie.domain, path: cookie.path)] = cookie
        }
        return map
    }
}

extension Notification.Name {
    /// Posted (on the main thread) for each cookie change the observer detects. Drives
    /// `chrome.cookies.onChanged`. userInfo: `change: [String: Any]` — a chrome change record
    /// `{ removed: Bool, cause: String, cookie: <chrome Cookie dict> }`. The fan-out is global
    /// (one store on iOS); each worker/page is free to ignore changes it doesn't care about.
    static let brownBearExtensionCookieDidChange = Notification.Name("brownBearExtensionCookieDidChange")
}
