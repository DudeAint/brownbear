//
//  WebExtContentResponseTable.swift
//  BrownBear
//
//  Correlates a native→content-script message push with the content script's eventual `sendResponse`.
//  When the runtime pushes a chrome.tabs.sendMessage into a content script, the script answers
//  asynchronously over the bridge with a `runtime.messageResponse` carrying the same id. This table
//  parks the awaiting caller against that id and resumes it when the response (or a timeout) arrives.
//
//  Split out from WebExtensionMessageRouter so the correlation logic is unit-testable without a live
//  WKWebView, and so the router stays under the SwiftLint complexity limit.
//

import Foundation

@MainActor
final class WebExtContentResponseTable {

    private var pending: [String: CheckedContinuation<Any?, Never>] = [:]
    private var counter = 0

    /// Number of outstanding (un-resolved) pushes — used by tests and for diagnostics.
    var outstanding: Int { pending.count }

    /// Park the current async caller, mint a correlation id, and hand it to `fire` so the caller can
    /// emit the push that carries it. Suspends until `resolve(id:value:)` is called with that id (or
    /// the caller's own timeout resolves it). `fire` runs synchronously while still on the MainActor,
    /// after the continuation is registered — so a response that races back can never be dropped.
    func wait(_ fire: (String) -> Void) async -> Any? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            counter += 1
            let id = "p\(counter)"
            pending[id] = continuation
            fire(id)
        }
    }

    /// Resume the caller parked under `id` with `value`. A no-op for an unknown id (a late/duplicate
    /// response, or one that already timed out), so a malicious or buggy content script can't crash
    /// us by replaying ids.
    func resolve(_ id: String, value: Any?) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: value)
    }

    /// Resume every outstanding caller with `nil` and clear the table — used when tearing down so no
    /// awaiting push is stranded.
    func drain() {
        for continuation in pending.values { continuation.resume(returning: nil) }
        pending.removeAll()
    }
}
