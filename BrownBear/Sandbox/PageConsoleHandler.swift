//
//  PageConsoleHandler.swift
//  BrownBear
//
//  Receives the page's own console.* output (forwarded by brownbear-pageconsole.js, which lives in
//  the PAGE content world) and records it as a LogEntry tagged `.page` (main frame) or `.iframe`
//  (subframe) for the dashboard Logs "Page" filter. The page world is untrusted, so this handler:
//    • performs NO privileged action — it only appends a capped log line;
//    • validates the message shape and caps the length;
//    • RATE-LIMITS ingestion (token bucket) so a hostile page spamming console.* in a tight loop
//      across many frames can't flood the store or pin the disk (the LogStore write is itself
//      debounced, but we also bound how many untrusted lines we accept);
//    • honors the user's "Capture page console" toggle.
//

import WebKit

final class PageConsoleHandler: NSObject, WKScriptMessageHandler {

    static let handlerName = "brownbearPageConsole"
    /// UserDefaults key for the capture toggle (mirrored by the Logs tab's @AppStorage switch).
    /// Absent == on, so capture is enabled by default until the user turns it off.
    static let captureDefaultsKey = "bbCapturePageConsole"

    private let logStore: LogStore
    private static let maxMessageLength = 4000
    /// Max page-console lines accepted per rolling second; excess is dropped and summarized. Errors/warnings
    /// get a SEPARATE budget from chatty info/log/debug output: a busy page (e.g. a userscript polling in a
    /// tight loop) can otherwise spam `console.log` past the cap and starve out the one `console.error` that
    /// explains a failure — exactly the line a developer needs. Both buckets stay bounded against flooding.
    private static let maxLinesPerSecond = 40
    private static let maxErrorsPerSecond = 40

    // Rate-limit state — only touched inside the @MainActor record(...) hop, so no extra locking.
    @MainActor private var windowStart = Date()
    @MainActor private var countThisWindow = 0
    @MainActor private var errorCountThisWindow = 0
    @MainActor private var suppressedThisWindow = 0

    init(logStore: LogStore) {
        self.logStore = logStore
        super.init()
    }

    private static var captureEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: captureDefaultsKey) == nil ? true : defaults.bool(forKey: captureDefaultsKey)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard Self.captureEnabled else { return }
        guard let body = message.body as? [String: Any] else { return }
        let level = LogEntry.Level(rawValue: (body["level"] as? String) ?? "info") ?? .info
        let raw = (body["message"] as? String) ?? ""
        guard !raw.isEmpty else { return }
        let text = raw.count > Self.maxMessageLength
            ? String(raw.prefix(Self.maxMessageLength)) + "…"
            : raw

        let isMainFrame = message.frameInfo.isMainFrame
        let host = message.frameInfo.securityOrigin.host
        let source: LogEntry.Source = isMainFrame ? .page : .iframe
        let name = host.isEmpty ? (isMainFrame ? "page" : "iframe") : host
        let receivedAt = Date()   // stamp at receive, not in the task body, to preserve ordering

        // WebKit delivers on the main thread; hop to the MainActor (like the other routers) so these
        // tasks enqueue in delivery order and the rate-limit state needs no extra synchronization.
        Task { @MainActor in
            await self.record(level: level, message: text, name: name, source: source, at: receivedAt)
        }
    }

    @MainActor
    private func record(level: LogEntry.Level, message: String, name: String,
                        source: LogEntry.Source, at receivedAt: Date) async {
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1 {
            let dropped = suppressedThisWindow
            windowStart = now
            countThisWindow = 0
            errorCountThisWindow = 0
            suppressedThisWindow = 0
            if dropped > 0 {
                await logStore.append(LogEntry(scriptID: nil, scriptName: name, level: .warn,
                                               message: "\(dropped) page console line(s) suppressed (rate limit)",
                                               createdAt: now, context: .foreground, source: source))
            }
        }
        // Errors and warnings draw from their own budget so a flood of info/log can't suppress them.
        let isDiagnostic = (level == .error || level == .warn)
        if isDiagnostic {
            guard errorCountThisWindow < Self.maxErrorsPerSecond else { suppressedThisWindow += 1; return }
            errorCountThisWindow += 1
        } else {
            guard countThisWindow < Self.maxLinesPerSecond else { suppressedThisWindow += 1; return }
            countThisWindow += 1
        }
        await logStore.append(LogEntry(scriptID: nil, scriptName: name, level: level,
                                       message: message, createdAt: receivedAt,
                                       context: .foreground, source: source))
    }
}
