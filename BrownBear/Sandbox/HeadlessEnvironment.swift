//
//  HeadlessEnvironment.swift
//  BrownBear
//
//  Web-environment values injected into headless JavaScriptCore contexts — the userscript background
//  runner (HeadlessScriptRunner) and each extension's MV3 service-worker context
//  (WebExtensionBackgroundContext). JSC ships no DOM, so `navigator` and `location` are simply absent
//  and any reference throws "Can't find variable: navigator / location", killing the script. Rather
//  than hard-code a stale string in JS, native supplies honest, device-derived values here and the JS
//  shims read them (with their own fallbacks) when building the polyfilled globals.
//

import Foundation

/// Device-derived values for the headless `navigator`/`location` polyfills. All members are pure value
/// reads (ProcessInfo / Locale) and therefore safe to call off the main thread — both headless contexts
/// run on background queues.
enum HeadlessEnvironment {

    /// A Mobile Safari user-agent string matching the running iOS/iPadOS version.
    ///
    /// We present a *plain* Mobile Safari UA (with the `Version/x` and `Safari/604.1` tokens a real
    /// Safari carries) rather than the live WKWebView default — userscripts routinely sniff for
    /// "Safari"/"Mobile" to branch behaviour, and the bare WKWebView UA (which omits `Version`/`Safari`)
    /// makes those checks misfire. The version is taken from the actual OS so the UA never goes stale.
    static var userAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion)_\(v.minorVersion)"
        let safariVersion = "\(v.majorVersion).\(v.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }

    /// The user's preferred BCP-47 language tag (e.g. "en-US"). Defaults to "en-US".
    static var language: String {
        let tag = Locale.preferredLanguages.first ?? "en-US"
        return tag.isEmpty ? "en-US" : tag
    }
}
