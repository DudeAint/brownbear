//
//  UserScriptMenuCommandStoreTests.swift
//  BrownBearTests
//
//  Coverage for the native backing of GM_registerMenuCommand and GM_getTab/GM_saveTab/GM_listTabs:
//  per-script tab-object namespacing (script A can never read script B's object — CLAUDE.md §5),
//  oversized-payload rejection (fail closed), per-tab forgetting on tab close, and the FIFO caps that
//  bound the shared, app-lifetime store. Menu-command register/replace/unregister and the per-web-view
//  filtering are exercised with a real WKWebView.
//

import XCTest
import WebKit
@testable import BrownBear

@MainActor
final class UserScriptMenuCommandStoreTests: XCTestCase {

    private func makeCommand(token: String,
                             commandID: String,
                             title: String = "Run",
                             scriptID: UUID = UUID(),
                             webView: WKWebView) -> UserScriptMenuCommand {
        UserScriptMenuCommand(scriptID: scriptID, scriptName: "S", token: token, commandID: commandID,
                              title: title, accessKey: nil, autoClose: true,
                              webView: webView, frameInfo: nil)
    }

    // MARK: - Tab objects

    func testTabObjectIsNamespacedPerScript() {
        let store = UserScriptMenuCommandStore()
        let scriptA = UUID()
        let scriptB = UUID()
        store.saveTabObject(tabID: 1, scriptID: scriptA, json: "{\"a\":1}")
        store.saveTabObject(tabID: 1, scriptID: scriptB, json: "{\"b\":2}")

        XCTAssertEqual(store.tabObject(tabID: 1, scriptID: scriptA), "{\"a\":1}")
        XCTAssertEqual(store.tabObject(tabID: 1, scriptID: scriptB), "{\"b\":2}")
        // Script A must never see script B's object for the same tab.
        XCTAssertNotEqual(store.tabObject(tabID: 1, scriptID: scriptA),
                          store.tabObject(tabID: 1, scriptID: scriptB))
    }

    func testTabObjectMissingReturnsNil() {
        let store = UserScriptMenuCommandStore()
        XCTAssertNil(store.tabObject(tabID: 99, scriptID: UUID()))
    }

    func testSaveTabObjectOverwritesSameKey() {
        let store = UserScriptMenuCommandStore()
        let script = UUID()
        store.saveTabObject(tabID: 2, scriptID: script, json: "{\"v\":1}")
        store.saveTabObject(tabID: 2, scriptID: script, json: "{\"v\":2}")
        XCTAssertEqual(store.tabObject(tabID: 2, scriptID: script), "{\"v\":2}")
    }

    func testOversizedTabObjectRejectedFailClosed() {
        let store = UserScriptMenuCommandStore()
        let script = UUID()
        let huge = String(repeating: "x", count: 256 * 1024 + 1)
        XCTAssertFalse(store.saveTabObject(tabID: 3, scriptID: script, json: huge))
        XCTAssertNil(store.tabObject(tabID: 3, scriptID: script))
        // A payload at the cap is accepted.
        let atCap = String(repeating: "y", count: 256 * 1024)
        XCTAssertTrue(store.saveTabObject(tabID: 3, scriptID: script, json: atCap))
    }

    func testListTabsReturnsOnlyThisScriptAcrossTabs() {
        let store = UserScriptMenuCommandStore()
        let mine = UUID()
        let other = UUID()
        store.saveTabObject(tabID: 1, scriptID: mine, json: "{\"t\":1}")
        store.saveTabObject(tabID: 2, scriptID: mine, json: "{\"t\":2}")
        store.saveTabObject(tabID: 1, scriptID: other, json: "{\"o\":1}")

        let listed = store.tabObjects(forScript: mine)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed[1], "{\"t\":1}")
        XCTAssertEqual(listed[2], "{\"t\":2}")
        XCTAssertNil(listed.values.first { $0.contains("\"o\"") })
    }

    func testForgetTabDropsThatTabsObjectsOnly() {
        let store = UserScriptMenuCommandStore()
        let script = UUID()
        store.saveTabObject(tabID: 1, scriptID: script, json: "{\"a\":1}")
        store.saveTabObject(tabID: 2, scriptID: script, json: "{\"b\":2}")
        store.forgetTab(tabID: 1)
        XCTAssertNil(store.tabObject(tabID: 1, scriptID: script))
        XCTAssertEqual(store.tabObject(tabID: 2, scriptID: script), "{\"b\":2}")
    }

    // MARK: - Menu commands

    func testRegisterReplaceByTokenAndCommandID() {
        let store = UserScriptMenuCommandStore()
        let webView = WKWebView()
        store.registerCommand(makeCommand(token: "t1", commandID: "c1", title: "First", webView: webView))
        store.registerCommand(makeCommand(token: "t1", commandID: "c1", title: "Second", webView: webView))
        let commands = store.commands(in: webView)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.title, "Second")
    }

    func testUnregisterRemovesOnlyTheNamedCommand() {
        let store = UserScriptMenuCommandStore()
        let webView = WKWebView()
        store.registerCommand(makeCommand(token: "t1", commandID: "c1", webView: webView))
        store.registerCommand(makeCommand(token: "t1", commandID: "c2", webView: webView))
        store.unregisterCommand(token: "t1", commandID: "c1")
        let commands = store.commands(in: webView)
        XCTAssertEqual(commands.map(\.commandID), ["c2"])
    }

    func testCommandLookupAndPurgeByWebView() {
        let store = UserScriptMenuCommandStore()
        let webViewA = WKWebView()
        let webViewB = WKWebView()
        store.registerCommand(makeCommand(token: "ta", commandID: "c1", webView: webViewA))
        store.registerCommand(makeCommand(token: "tb", commandID: "c1", webView: webViewB))

        XCTAssertNotNil(store.command(token: "ta", commandID: "c1"))
        XCTAssertEqual(store.commands(in: webViewA).count, 1)
        XCTAssertEqual(store.commands(in: webViewB).count, 1)

        store.purge(webView: webViewA)
        XCTAssertNil(store.command(token: "ta", commandID: "c1"))
        XCTAssertTrue(store.commands(in: webViewA).isEmpty)
        // Other web view's command survives.
        XCTAssertEqual(store.commands(in: webViewB).count, 1)
    }

    func testPerTokenCapEvictsOldest() {
        let store = UserScriptMenuCommandStore()
        let webView = WKWebView()
        // 60 registrations under one token; the per-token cap is 50, oldest dropped.
        for i in 0..<60 {
            store.registerCommand(makeCommand(token: "t", commandID: "c\(i)", webView: webView))
        }
        let commands = store.commands(in: webView)
        XCTAssertEqual(commands.count, 50)
        // The oldest 10 (c0…c9) were evicted; c10…c59 remain.
        XCTAssertNil(commands.first { $0.commandID == "c0" })
        XCTAssertNotNil(commands.first { $0.commandID == "c59" })
    }
}
