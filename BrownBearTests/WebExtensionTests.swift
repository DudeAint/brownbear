//
//  WebExtensionTests.swift
//  BrownBearTests
//
//  Tests for the Web Extensions foundation: manifest parsing (MV2/MV3 polymorphic shapes), the
//  dependency-free ZIP/CRX reader, the install/store flow, and per-extension/per-area storage
//  isolation.
//

import XCTest
@testable import BrownBear

// MARK: - A minimal STORED-method ZIP builder for tests (no compression, crc ignored by reader).

enum TestZip {
    static func make(_ files: [(name: String, data: Data)]) -> Data {
        func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

        var local = Data()
        var offsets: [Int] = []
        for file in files {
            offsets.append(local.count)
            let name = Data(file.name.utf8)
            local.append(u32(0x0403_4b50)); local.append(u16(20)); local.append(u16(0))
            local.append(u16(0)); local.append(u16(0)); local.append(u16(0)); local.append(u32(0))
            local.append(u32(UInt32(file.data.count))); local.append(u32(UInt32(file.data.count)))
            local.append(u16(UInt16(name.count))); local.append(u16(0))
            local.append(name); local.append(file.data)
        }
        let centralStart = local.count
        var central = Data()
        for (index, file) in files.enumerated() {
            let name = Data(file.name.utf8)
            central.append(u32(0x0201_4b50)); central.append(u16(20)); central.append(u16(20))
            central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0))
            central.append(u32(0))
            central.append(u32(UInt32(file.data.count))); central.append(u32(UInt32(file.data.count)))
            central.append(u16(UInt16(name.count))); central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0)); central.append(u32(0))
            central.append(u32(UInt32(offsets[index]))); central.append(name)
        }
        var zip = local
        zip.append(central)
        zip.append(u32(0x0605_4b50)); zip.append(u16(0)); zip.append(u16(0))
        zip.append(u16(UInt16(files.count))); zip.append(u16(UInt16(files.count)))
        zip.append(u32(UInt32(central.count))); zip.append(u32(UInt32(centralStart))); zip.append(u16(0))
        return zip
    }

    /// Wrap a ZIP in a minimal CRX3 header (magic + version 3 + zero-length protobuf header).
    static func wrapCRX3(_ zip: Data) -> Data {
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var crx = Data("Cr24".utf8)
        crx.append(u32(3))   // version
        crx.append(u32(0))   // header size (no protobuf)
        crx.append(zip)
        return crx
    }
}

// MARK: - Manifest

final class WebExtensionManifestTests: XCTestCase {

    func testParsesManifestV3() throws {
        let json = """
        {
          "manifest_version": 3,
          "name": "Test Ext",
          "version": "1.2.3",
          "description": "Does things",
          "default_locale": "en",
          "icons": { "16": "i16.png", "48": "i48.png" },
          "action": { "default_title": "T", "default_popup": "popup.html", "default_icon": "a.png" },
          "permissions": ["storage", "tabs"],
          "host_permissions": ["*://*.example.com/*"],
          "content_scripts": [
            { "matches": ["*://*.example.com/*"], "js": ["cs.js"], "css": ["cs.css"], "run_at": "document_start", "all_frames": true }
          ],
          "background": { "service_worker": "sw.js", "type": "module" },
          "web_accessible_resources": [ { "resources": ["img/*"], "matches": ["*://*.example.com/*"] } ],
          "content_security_policy": { "extension_pages": "script-src 'self'" }
        }
        """
        let meta = try WebExtensionManifest.parse(Data(json.utf8))
        XCTAssertEqual(meta.manifestVersion, 3)
        XCTAssertEqual(meta.name, "Test Ext")
        XCTAssertEqual(meta.version, "1.2.3")
        XCTAssertEqual(meta.icons["48"], "i48.png")
        XCTAssertEqual(meta.permissions.sorted(), ["storage", "tabs"])
        XCTAssertEqual(meta.hostPermissions, ["*://*.example.com/*"])
        XCTAssertEqual(meta.contentScripts.count, 1)
        XCTAssertEqual(meta.contentScripts[0].runAt, "document_start")
        XCTAssertTrue(meta.contentScripts[0].allFrames)
        XCTAssertEqual(meta.background?.serviceWorker, "sw.js")
        XCTAssertTrue(meta.background?.isModule ?? false)
        XCTAssertEqual(meta.action?.defaultPopup, "popup.html")
        XCTAssertEqual(meta.action?.defaultIcon["0"], "a.png")
        XCTAssertEqual(meta.webAccessibleResources.first?.resources, ["img/*"])
        XCTAssertEqual(meta.contentSecurityPolicy, "script-src 'self'")
    }

    func testParsesManifestV2PolymorphicShapes() throws {
        let json = """
        {
          "manifest_version": 2,
          "name": "Old Ext",
          "version": "0.9",
          "browser_action": { "default_icon": { "19": "a19.png", "38": "a38.png" } },
          "permissions": ["storage", "*://*.test.com/*", "<all_urls>"],
          "background": { "scripts": ["bg.js"], "persistent": false },
          "web_accessible_resources": ["web/*.png", "data.json"],
          "content_security_policy": "default-src 'self'"
        }
        """
        let meta = try WebExtensionManifest.parse(Data(json.utf8))
        XCTAssertEqual(meta.manifestVersion, 2)
        // MV2 mixes host patterns into permissions; they should be split out.
        XCTAssertEqual(meta.permissions, ["storage"])
        XCTAssertEqual(meta.hostPermissions.sorted(), ["*://*.test.com/*", "<all_urls>"])
        XCTAssertEqual(meta.background?.scripts, ["bg.js"])
        XCTAssertEqual(meta.action?.defaultIcon["19"], "a19.png")
        // MV2 web_accessible_resources is a flat string array.
        XCTAssertEqual(meta.webAccessibleResources.first?.resources, ["web/*.png", "data.json"])
        XCTAssertEqual(meta.contentSecurityPolicy, "default-src 'self'")
    }

    func testRejectsMissingNameOrVersion() {
        XCTAssertThrowsError(try WebExtensionManifest.parse(Data(#"{"manifest_version":3,"version":"1"}"#.utf8)))
        XCTAssertThrowsError(try WebExtensionManifest.parse(Data(#"{"manifest_version":3,"name":"x"}"#.utf8)))
    }

    func testParsesDeclarativeNetRequestAndCommands() throws {
        let json = """
        {
          "manifest_version": 3,
          "name": "Blocker",
          "version": "1.0",
          "declarative_net_request": {
            "rule_resources": [
              { "id": "ads", "enabled": true, "path": "rules/ads.json" },
              { "id": "social", "enabled": false, "path": "rules/social.json" },
              { "path": "rules/incomplete.json" }
            ]
          },
          "commands": {
            "toggle": { "suggested_key": { "default": "Ctrl+Shift+Y" }, "description": "Toggle" },
            "_execute_action": { "suggested_key": "Ctrl+Shift+A" }
          }
        }
        """
        let meta = try WebExtensionManifest.parse(Data(json.utf8))
        XCTAssertEqual(meta.declarativeNetRequest.count, 2)   // the id-less entry is dropped
        XCTAssertEqual(meta.declarativeNetRequest[0].id, "ads")
        XCTAssertTrue(meta.declarativeNetRequest[0].enabled)
        XCTAssertEqual(meta.declarativeNetRequest[1].id, "social")
        XCTAssertFalse(meta.declarativeNetRequest[1].enabled)

        XCTAssertEqual(meta.commands.count, 2)
        // Commands are sorted by name for stable iteration.
        XCTAssertEqual(meta.commands.map(\.name), ["_execute_action", "toggle"])
        XCTAssertEqual(meta.commands.first { $0.name == "toggle" }?.suggestedKey, "Ctrl+Shift+Y")
        XCTAssertEqual(meta.commands.first { $0.name == "_execute_action" }?.suggestedKey, "Ctrl+Shift+A")
    }
}

// MARK: - Chrome Web Store

final class ChromeWebStoreTests: XCTestCase {

    func testExtractsExtensionIDFromBareID() {
        let id = "abcdefghijklmnopabcdefghijklmnop"  // 32 chars, a–p
        XCTAssertEqual(ChromeWebStore.extensionID(from: id), id)
        XCTAssertTrue(ChromeWebStore.isExtensionID(id))
    }

    func testExtractsExtensionIDFromStoreURLs() {
        let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"  // uBlock Origin's real id (all a–p)
        XCTAssertEqual(
            ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/ublock-origin/\(id)"), id)
        XCTAssertEqual(
            ChromeWebStore.extensionID(from: "https://chrome.google.com/webstore/detail/ublock-origin/\(id)?hl=en"), id)
    }

    func testRejectsNonIDs() {
        XCTAssertNil(ChromeWebStore.extensionID(from: "https://example.com/not-an-extension"))
        XCTAssertNil(ChromeWebStore.extensionID(from: "tooshort"))
        XCTAssertFalse(ChromeWebStore.isExtensionID("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP")) // uppercase out of a–p
        XCTAssertFalse(ChromeWebStore.isExtensionID("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")) // z is past p
    }

    func testBuildsDownloadURL() throws {
        let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
        let url = try XCTUnwrap(ChromeWebStore.downloadURL(extensionID: id))
        let string = url.absoluteString
        XCTAssertTrue(string.hasPrefix("https://clients2.google.com/service/update2/crx"))
        XCTAssertTrue(string.contains("response=redirect"))
        XCTAssertTrue(string.contains("acceptformat=crx2,crx3"))
        // The nested x blob must be percent-encoded so its inner & doesn't split the query.
        XCTAssertFalse(string.contains("x=id="))
        XCTAssertTrue(string.contains(id))
    }
}

// MARK: - Archive

final class WebExtensionArchiveTests: XCTestCase {

    func testUnpacksStoredZip() throws {
        let files: [(name: String, data: Data)] = [
            ("manifest.json", Data(#"{"name":"a"}"#.utf8)),
            ("js/content.js", Data("console.log('hi');".utf8))
        ]
        let unpacked = try WebExtensionArchive.unpack(TestZip.make(files))
        XCTAssertEqual(unpacked["manifest.json"], Data(#"{"name":"a"}"#.utf8))
        XCTAssertEqual(unpacked["js/content.js"], Data("console.log('hi');".utf8))
    }

    func testStripsCRX3Header() throws {
        let files = [(name: "manifest.json", data: Data(#"{"name":"crx"}"#.utf8))]
        let crx = TestZip.wrapCRX3(TestZip.make(files))
        let unpacked = try WebExtensionArchive.unpack(crx)
        XCTAssertEqual(unpacked["manifest.json"], Data(#"{"name":"crx"}"#.utf8))
    }

    func testRejectsNonArchive() {
        XCTAssertThrowsError(try WebExtensionArchive.unpack(Data("not a zip".utf8)))
    }
}

// MARK: - Store

final class WebExtensionStoreTests: XCTestCase {

    func testInstallParsesPersistsAndReadsFiles() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let manifest = #"{"manifest_version":3,"name":"Installer","version":"1.0","content_scripts":[{"matches":["*://*/*"],"js":["c.js"]}]}"#
        let archive = TestZip.make([
            (name: "manifest.json", data: Data(manifest.utf8)),
            (name: "c.js", data: Data("/* content */".utf8))
        ])

        let store = WebExtensionStore(baseDirectory: baseDir)
        let installed = try await store.install(archive: archive)
        XCTAssertEqual(installed.manifest?.name, "Installer")
        XCTAssertEqual(installed.id.count, 32)

        // File readable from disk.
        let js = await store.text(extensionID: installed.id, path: "c.js")
        XCTAssertEqual(js, "/* content */")

        // Survives a fresh store over the same directory.
        let reopened = WebExtensionStore(baseDirectory: baseDir)
        let all = await reopened.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.displayName, "Installer")
    }

    func testFileRejectsMaliciousExtensionIDAndPath() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        // A file sitting in the base dir (the global index lives here) must not be reachable.
        try Data("SECRET".utf8).write(to: baseDir.appendingPathComponent("index.json"))

        let store = WebExtensionStore(baseDirectory: baseDir)
        // A `..` host would relocate the per-id root up and out — must be rejected.
        let viaDotDot = await store.file(extensionID: "..", path: "index.json")
        XCTAssertNil(viaDotDot)
        let viaEscape = await store.file(extensionID: "../../secret", path: "x")
        XCTAssertNil(viaEscape)
        // A non-32-char / non-a–p id is rejected outright.
        let viaShort = await store.file(extensionID: "short", path: "index.json")
        XCTAssertNil(viaShort)
        // A well-formed id with a traversal path is also contained.
        let validID = String(repeating: "a", count: 32)
        let viaPath = await store.file(extensionID: validID, path: "../index.json")
        XCTAssertNil(viaPath)
    }

    func testRejectsArchiveWithoutManifest() async {
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("bb-ext-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let archive = TestZip.make([(name: "readme.txt", data: Data("hi".utf8))])
        let store = WebExtensionStore(baseDirectory: baseDir)
        do {
            _ = try await store.install(archive: archive)
            XCTFail("should reject an archive with no manifest.json")
        } catch {
            // expected
        }
    }
}

// MARK: - Storage

final class WebExtensionStorageTests: XCTestCase {

    private func makeStorage() -> WebExtensionStorage {
        WebExtensionStorage(suiteName: "brownbear.webext.test.\(UUID().uuidString)")
    }

    func testIsolatesByExtensionAndArea() async {
        let storage = makeStorage()
        await storage.set(extensionID: "extA", area: .local, items: ["k": "1"])
        await storage.set(extensionID: "extB", area: .local, items: ["k": "2"])
        await storage.set(extensionID: "extA", area: .sync, items: ["k": "3"])

        let a = await storage.get(extensionID: "extA", area: .local, keys: nil)
        let b = await storage.get(extensionID: "extB", area: .local, keys: nil)
        let aSync = await storage.get(extensionID: "extA", area: .sync, keys: nil)
        XCTAssertEqual(a["k"], "1")
        XCTAssertEqual(b["k"], "2")           // different extension, isolated
        XCTAssertEqual(aSync["k"], "3")       // different area, isolated
    }

    func testRemoveAndClear() async {
        let storage = makeStorage()
        await storage.set(extensionID: "e", area: .local, items: ["a": "1", "b": "2"])
        await storage.remove(extensionID: "e", area: .local, keys: ["a"])
        var values = await storage.get(extensionID: "e", area: .local, keys: nil)
        XCTAssertNil(values["a"])
        XCTAssertEqual(values["b"], "2")

        await storage.clear(extensionID: "e", area: .local)
        values = await storage.get(extensionID: "e", area: .local, keys: nil)
        XCTAssertTrue(values.isEmpty)
    }

    func testSetReportsChangesAndSkipsNoOps() async {
        let storage = makeStorage()
        let first = await storage.set(extensionID: "e", area: .local, items: ["k": "\"v\""])
        XCTAssertEqual(first["k"]?.old, nil)
        XCTAssertEqual(first["k"]?.new, "\"v\"")

        // Re-setting the identical value is a no-op — no change is reported (and onChanged won't fire).
        let second = await storage.set(extensionID: "e", area: .local, items: ["k": "\"v\""])
        XCTAssertTrue(second.isEmpty)

        // Changing it does report old → new.
        let third = await storage.set(extensionID: "e", area: .local, items: ["k": "\"w\""])
        XCTAssertEqual(third["k"]?.old, "\"v\"")
        XCTAssertEqual(third["k"]?.new, "\"w\"")

        // Clear reports the removed keys.
        let cleared = await storage.clear(extensionID: "e", area: .local)
        XCTAssertEqual(cleared["k"]?.old, "\"w\"")
        XCTAssertNil(cleared["k"]?.new ?? nil)
    }
}
