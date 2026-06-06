//
//  UserScriptInstallerTests.swift
//  BrownBearTests
//
//  Tests the shared install engine behind "Import from URL" and the browser's one-tap *.user.js
//  install: URL detection, metadata preview, file fetch, and add-vs-update routing.
//

import XCTest
@testable import BrownBear

final class UserScriptInstallerTests: XCTestCase {

    private let sample = """
    // ==UserScript==
    // @name        Test Importer
    // @namespace   bb.test
    // @version     1.0
    // @description Imports things
    // @author      Ada
    // @match       *://*.example.com/*
    // @grant       GM_setValue
    // ==/UserScript==
    console.log('hi');
    """

    private func makeStore() -> ScriptStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-scripts-\(UUID().uuidString).json")
        return ScriptStore(fileURL: url)
    }

    // MARK: - URL detection

    func testIsUserScriptURL() {
        XCTAssertTrue(UserScriptInstaller.isUserScriptURL(URL(string: "https://greasyfork.org/scripts/x/code/My%20Script.user.js")!))
        XCTAssertTrue(UserScriptInstaller.isUserScriptURL(URL(string: "https://example.com/a.user.js")!))
        XCTAssertTrue(UserScriptInstaller.isUserScriptURL(URL(string: "https://example.com/A.USER.JS")!))
        XCTAssertFalse(UserScriptInstaller.isUserScriptURL(URL(string: "https://example.com/app.js")!))
        XCTAssertFalse(UserScriptInstaller.isUserScriptURL(URL(string: "https://example.com/user.js.html")!))
        XCTAssertFalse(UserScriptInstaller.isUserScriptURL(URL(string: "https://example.com/")!))
    }

    // MARK: - Preview

    @MainActor
    func testMakePreviewParsesMetadata() async throws {
        let installer = UserScriptInstaller(scriptStore: makeStore())
        let preview = try await installer.makePreview(source: sample, url: URL(string: "https://x/s.user.js"))
        XCTAssertEqual(preview.metadata.name, "Test Importer")
        XCTAssertEqual(preview.metadata.namespace, "bb.test")
        XCTAssertEqual(preview.metadata.version, "1.0")
        XCTAssertEqual(preview.metadata.matches, ["*://*.example.com/*"])
        XCTAssertEqual(preview.metadata.grants, ["GM_setValue"])
        XCTAssertFalse(preview.isUpdate)
        XCTAssertFalse(preview.runsOnNoPages)
        XCTAssertGreaterThan(preview.lineCount, 1)
    }

    @MainActor
    func testPreviewFlagsScriptThatRunsOnNoPages() async throws {
        let noMatch = """
        // ==UserScript==
        // @name No Match
        // @version 1.0
        // ==/UserScript==
        console.log('x');
        """
        let installer = UserScriptInstaller(scriptStore: makeStore())
        let preview = try await installer.makePreview(source: noMatch, url: nil)
        XCTAssertTrue(preview.runsOnNoPages)
    }

    @MainActor
    func testRejectsSourceWithoutMetadataBlock() async {
        let installer = UserScriptInstaller(scriptStore: makeStore())
        do {
            _ = try await installer.makePreview(source: "console.log('no header');", url: nil)
            XCTFail("a source with no ==UserScript== block should not preview")
        } catch {
            // expected
        }
    }

    // MARK: - Install / update

    @MainActor
    func testInstallAddsThenUpdatesInPlace() async throws {
        let store = makeStore()
        let installer = UserScriptInstaller(scriptStore: store)

        // First install adds a new script.
        let preview1 = try await installer.makePreview(source: sample, url: nil)
        XCTAssertFalse(preview1.isUpdate)
        _ = try await installer.install(preview1)
        var all = await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.metadata.version, "1.0")

        // Same @name + @namespace, new @version → detected as an update, replaces in place.
        // (1.0 appears only in @version, so a plain replace is safe.)
        let v2 = sample.replacingOccurrences(of: "1.0", with: "2.0")
        let preview2 = try await installer.makePreview(source: v2, url: nil)
        XCTAssertTrue(preview2.isUpdate)
        XCTAssertEqual(preview2.existingVersion, "1.0")
        _ = try await installer.install(preview2)
        all = await store.all()
        XCTAssertEqual(all.count, 1, "an update must not create a second copy")
        XCTAssertEqual(all.first?.metadata.version, "2.0")
    }

    // MARK: - Fetch

    @MainActor
    func testFetchFromFileURL() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-\(UUID().uuidString).user.js")
        try sample.data(using: .utf8)!.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let installer = UserScriptInstaller(scriptStore: makeStore())
        let fetched = try await installer.fetchSource(from: fileURL)
        XCTAssertEqual(fetched, sample)

        let preview = try await installer.preview(url: fileURL)
        XCTAssertEqual(preview.metadata.name, "Test Importer")
        XCTAssertEqual(preview.sourceURL, fileURL)
    }
}
