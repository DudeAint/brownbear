//
//  WebStoreInstallTests.swift
//  BrownBearTests
//
//  The Chrome Web Store install bookkeeping that backs the in-page "Add / Remove from BrownBear"
//  button: recording the originating store id, looking an installed extension back up by it, and
//  re-installing from the same store page replacing (not duplicating) the prior copy.
//

import XCTest
@testable import BrownBear

final class WebStoreInstallTests: XCTestCase {

    private func archive(name: String) -> Data {
        let manifest = "{\"manifest_version\":3,\"name\":\"\(name)\",\"version\":\"1.0\"}"
        return TestZip.make([
            (name: "manifest.json", data: Data(manifest.utf8)),
            (name: "c.js", data: Data("/* content */".utf8))
        ])
    }

    private func tempStore() -> (WebExtensionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-store-\(UUID().uuidString)")
        return (WebExtensionStore(baseDirectory: dir), dir)
    }

    private let storeID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    func testStoreIDRecordedAndLookedUp() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let installed = try await store.install(archive: archive(name: "Blocker"), storeID: storeID)
        XCTAssertEqual(installed.storeID, storeID)
        XCTAssertNotEqual(installed.id, storeID, "the local id is generated, not the store id")

        let found = await store.installed(forStoreID: storeID)
        XCTAssertEqual(found?.id, installed.id)
        let missing = await store.installed(forStoreID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertNil(missing)
    }

    func testSideloadedArchiveHasNoStoreID() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let installed = try await store.install(archive: archive(name: "Sideload"))
        XCTAssertNil(installed.storeID)
        let found = await store.installed(forStoreID: storeID)
        XCTAssertNil(found)
    }

    func testReinstallFromSameStorePageReplaces() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try await store.install(archive: archive(name: "V1"), storeID: storeID)
        let second = try await store.install(archive: archive(name: "V2"), storeID: storeID)

        let all = await store.all()
        XCTAssertEqual(all.count, 1, "re-installing the same store id replaces, never duplicates")
        XCTAssertEqual(all.first?.id, second.id)
        XCTAssertNotEqual(first.id, second.id)
        let superseded = await store.ext(for: first.id)
        XCTAssertNil(superseded, "the superseded copy is gone")
    }

    func testStoreIDSurvivesReopen() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await store.install(archive: archive(name: "Persisted"), storeID: storeID)
        let reopened = WebExtensionStore(baseDirectory: dir)
        let found = await reopened.installed(forStoreID: storeID)
        XCTAssertEqual(found?.displayName, "Persisted")
    }

    func testCodableRoundTripPreservesStoreID() throws {
        let ext = WebExtension(id: String(repeating: "a", count: 32),
                               manifestJSON: "{\"name\":\"X\",\"version\":\"1\"}",
                               storeID: storeID)
        let data = try JSONEncoder().encode(ext)
        let decoded = try JSONDecoder().decode(WebExtension.self, from: data)
        XCTAssertEqual(decoded.storeID, storeID)
    }
}
