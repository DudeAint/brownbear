//
//  WebExtensionUserScriptStoreTests.swift
//  BrownBearTests
//
//  Tests chrome.userScripts registration storage: register/getScripts/update/unregister with id
//  validation, configureWorld round-trip, and persistence. Isolated UserDefaults suite per test.
//

import XCTest
@testable import BrownBear

final class WebExtensionUserScriptStoreTests: XCTestCase {

    private func makeStore() -> WebExtensionUserScriptStore {
        let suite = "test.webext.userscripts.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return WebExtensionUserScriptStore(suiteName: suite)
    }

    private func script(_ id: String, js: String = "console.log(1)") -> WebExtensionUserScriptStore.RegisteredScript {
        .init(id: id, matches: ["https://example.com/*"], excludeMatches: [], includeGlobs: [],
              excludeGlobs: [], js: js, runAt: "document_idle", allFrames: false, world: "USER_SCRIPT")
    }

    func testRegisterAndGet() async throws {
        let store = makeStore()
        try await store.register(extensionID: "e", scripts: [script("a"), script("b")])
        let all = await store.getScripts(extensionID: "e", ids: nil)
        XCTAssertEqual(all.map(\.id), ["a", "b"])
        let filtered = await store.getScripts(extensionID: "e", ids: ["b"])
        XCTAssertEqual(filtered.map(\.id), ["b"])
    }

    func testRegisterDuplicateIdRejected() async throws {
        let store = makeStore()
        try await store.register(extensionID: "e", scripts: [script("a")])
        do {
            try await store.register(extensionID: "e", scripts: [script("a")])
            XCTFail("expected duplicate-id rejection")
        } catch {
            let all = await store.getScripts(extensionID: "e", ids: nil)
            XCTAssertEqual(all.count, 1, "a rejected register must not duplicate")
        }
    }

    func testUpdateReplacesBody() async throws {
        let store = makeStore()
        try await store.register(extensionID: "e", scripts: [script("a", js: "OLD")])
        try await store.update(extensionID: "e", scripts: [script("a", js: "NEW")])
        let all = await store.getScripts(extensionID: "e", ids: nil)
        XCTAssertEqual(all.first?.js, "NEW")
    }

    func testUpdateUnknownIdRejected() async {
        let store = makeStore()
        do {
            try await store.update(extensionID: "e", scripts: [script("ghost")])
            XCTFail("expected unknown-id rejection")
        } catch { /* expected */ }
    }

    func testUnregisterByIdAndAll() async throws {
        let store = makeStore()
        try await store.register(extensionID: "e", scripts: [script("a"), script("b"), script("c")])
        await store.unregister(extensionID: "e", ids: ["b"])
        let afterOne = await store.getScripts(extensionID: "e", ids: nil)
        XCTAssertEqual(afterOne.map(\.id), ["a", "c"])
        await store.unregister(extensionID: "e", ids: nil)
        let afterAll = await store.getScripts(extensionID: "e", ids: nil)
        XCTAssertTrue(afterAll.isEmpty)
    }

    func testConfigureWorldRoundTrips() async throws {
        let store = makeStore()
        await store.configureWorld(extensionID: "e", config: .init(worldId: nil, csp: "script-src 'self'", messaging: true))
        await store.configureWorld(extensionID: "e", config: .init(worldId: "w2", csp: nil, messaging: false))
        let configs = await store.worldConfigs(extensionID: "e")
        XCTAssertEqual(configs.count, 2)
        XCTAssertEqual(configs.first { $0.worldId == nil }?.csp, "script-src 'self'")
    }

    func testScriptsPersistAcrossInstances() async throws {
        let suite = "test.webext.userscripts.persist.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let first = WebExtensionUserScriptStore(suiteName: suite)
        try await first.register(extensionID: "p", scripts: [script("x")])
        let reopened = WebExtensionUserScriptStore(suiteName: suite)
        let persisted = await reopened.getScripts(extensionID: "p", ids: nil)
        XCTAssertEqual(persisted.map(\.id), ["x"])
    }
}
