//
//  PageWorldHandlerTests.swift
//  BrownBearTests
//
//  Pins the security-critical allowlist behind the RESTRICTED page-world message handler
//  (`brownbearPage`). A granted page-world userscript reaches native through the document-start vault's
//  `window.__bbPageGM(token, api, payload)`; the router's `fromPageWorld` guard then rejects ANY api not
//  in `ScriptMessageRouter.pageWorldWriteAPIs`. That set is therefore the entire native attack surface a
//  page-world caller can touch — it MUST be limited to a script's own-data writes and MUST NOT contain a
//  token-minting (getScripts), code-injecting (injectPageWorld), or cross-origin (GM_xmlhttpRequest,
//  cookies, downloads) API. A regression that widens this set is a privilege escalation, so it is pinned
//  here. (The guard wiring itself — message.name → fromPageWorld → route() — is exercised end-to-end by
//  the CI Build & Test job, since WKScriptMessage cannot be constructed in a unit test.)
//

import XCTest
@testable import BrownBear

final class PageWorldHandlerTests: XCTestCase {

    func testAllowlistIsExactlyTheOwnDataWriteAPIs() {
        // Own-data writes + console `log` + GM_xmlhttpRequest/GM_abortRequest (response native→page via
        // __bbPageXHR) + the request→reply APIs GM_cookie/getTab/saveTab/listTabs (result returned through
        // the reply promise, settled via the vault's pristine `.then` into the caller's closure — never DOM).
        XCTAssertEqual(ScriptMessageRouter.pageWorldWriteAPIs,
                       ["GM_setValue", "GM_deleteValue", "GM_setValues", "GM_deleteValues",
                        "GM_setClipboard", "GM_log", "log", "GM_xmlhttpRequest", "GM_abortRequest",
                        "GM_cookie", "GM_getTab", "GM_saveTab", "GM_listTabs"],
                       "the page-world allowlist is the own-data writes + log + xhr + cookie/tab request-reply")
    }

    func testAllowlistExcludesPrivilegedAndStreamingCallbackAPIs() {
        // The escalation-sensitive APIs: token minting, code injection, session revival, and the
        // STREAMING-callback ones not yet routed to the page world. NONE may be reachable.
        let forbidden = [
            "getScripts", "injectPageWorld", "revalidateSessions",
            "GM_download", "GM_notification", "GM_notificationClear",
            "GM_openInTab", "GM_registerMenuCommand", "GM_unregisterMenuCommand",
            "fetchResource", "GM_downloadAbort", "GM_closeTab"
        ]
        for api in forbidden {
            XCTAssertFalse(ScriptMessageRouter.pageWorldWriteAPIs.contains(api),
                           "\(api) must NOT be reachable from the page world")
        }
    }

    func testReadAPIsAreNotInTheWriteAllowlist() {
        // Reads are served page-local from the pre-seeded cache and must never relay to native — so they
        // are absent from the write allowlist too (a page-world read never hits this handler).
        for api in ["GM_getValue", "GM_listValues", "GM_getValues", "GM_getResourceText", "GM_getResourceURL"] {
            XCTAssertFalse(ScriptMessageRouter.pageWorldWriteAPIs.contains(api),
                           "\(api) is served page-local and must not be in the write allowlist")
        }
    }

    func testPageHandlerNameIsDistinctFromTheIsolatedHandler() {
        // The page-world handler is registered under its own name so a page script cannot reach the full
        // isolated `brownbear` handler (which is never registered in WKContentWorld.page).
        XCTAssertEqual(ScriptMessageRouter.pageHandlerName, "brownbearPage")
        XCTAssertNotEqual(ScriptMessageRouter.pageHandlerName, ScriptMessageRouter.handlerName)
    }
}
