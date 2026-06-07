//
//  ScriptOverridesTests.swift
//  BrownBearTests
//
//  Per-script overrides (the Tampermonkey/ScriptCat "script settings" surface): effective-value
//  resolution layered over @metadata, Codable backward-compatibility for records saved before the
//  field existed, and ScriptStore pruning an emptied override back to nil so untouched scripts stay
//  clean in storage.
//

import XCTest
@testable import BrownBear

final class ScriptOverridesTests: XCTestCase {

    private let sampleSource = """
    // ==UserScript==
    // @name        Sample
    // @version     1.0
    // @match       https://example.com/*
    // @run-at      document-end
    // @inject-into content
    // @downloadURL https://example.com/sample.user.js
    // ==/UserScript==
    console.log("hi");
    """

    private func makeScript() throws -> UserScript {
        try UserScript.make(from: sampleSource)
    }

    // MARK: - isEmpty

    func testIsEmpty() {
        XCTAssertTrue(ScriptOverrides().isEmpty)
        XCTAssertFalse(ScriptOverrides(runAt: .documentStart).isEmpty)
        XCTAssertFalse(ScriptOverrides(injectInto: .page).isEmpty)
        XCTAssertFalse(ScriptOverrides(autoUpdate: false).isEmpty)
    }

    // MARK: - Effective values

    func testEffectiveValuesFallBackToMetadataWhenNoOverride() throws {
        let script = try makeScript()
        XCTAssertNil(script.overrides)
        XCTAssertEqual(script.effectiveRunAt, .documentEnd)        // from @run-at
        XCTAssertEqual(script.effectiveInjectInto, .content)       // from @inject-into
    }

    func testOverrideTakesPrecedenceOverMetadata() throws {
        var script = try makeScript()
        script.overrides = ScriptOverrides(runAt: .documentStart, injectInto: .page)
        XCTAssertEqual(script.effectiveRunAt, .documentStart)
        XCTAssertEqual(script.effectiveInjectInto, .page)
    }

    func testPartialOverrideOnlyAffectsSetField() throws {
        var script = try makeScript()
        script.overrides = ScriptOverrides(runAt: .documentIdle)   // injectInto unset
        XCTAssertEqual(script.effectiveRunAt, .documentIdle)       // overridden
        XCTAssertEqual(script.effectiveInjectInto, .content)       // still from metadata
    }

    // MARK: - Codable backward-compatibility

    func testDecodingRecordWithoutOverridesFieldYieldsNil() throws {
        // A record saved before `overrides` existed has no such key. Synthesized Codable must treat
        // the optional as absent (nil), not fail to decode.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "source": \(try jsonString(sampleSource)),
          "metadata": \(try encodedMetadata()),
          "enabled": true,
          "createdAt": "1970-01-01T00:00:00Z",
          "updatedAt": "1970-01-01T00:00:00Z"
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder.brownBear.decode(UserScript.self, from: data)
        XCTAssertNil(decoded.overrides)
        XCTAssertEqual(decoded.effectiveRunAt, .documentEnd)
    }

    func testOverridesRoundTripThroughCodable() throws {
        var script = try makeScript()
        script.overrides = ScriptOverrides(runAt: .documentStart, injectInto: .page, autoUpdate: false)
        let data = try JSONEncoder.brownBear.encode(script)
        let decoded = try JSONDecoder.brownBear.decode(UserScript.self, from: data)
        XCTAssertEqual(decoded.overrides, script.overrides)
        XCTAssertEqual(decoded.effectiveRunAt, .documentStart)
        XCTAssertEqual(decoded.overrides?.autoUpdate, false)
    }

    // MARK: - ScriptStore.setOverrides

    func testSetOverridesPersistsAndPrunesEmpty() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-overrides-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScriptStore(fileURL: url)
        let installed = try await store.add(source: sampleSource)

        // Apply a non-empty override.
        let updated = await store.setOverrides(id: installed.id,
                                               ScriptOverrides(runAt: .documentStart, autoUpdate: false))
        XCTAssertEqual(updated?.overrides?.runAt, .documentStart)
        XCTAssertEqual(updated?.overrides?.autoUpdate, false)

        // Clearing every field prunes the struct back to nil rather than persisting an empty object.
        let pruned = await store.setOverrides(id: installed.id, ScriptOverrides())
        XCTAssertNil(pruned?.overrides)

        // Unknown id is a no-op returning nil.
        let missing = await store.setOverrides(id: UUID(), ScriptOverrides(runAt: .documentEnd))
        XCTAssertNil(missing)
    }

    // MARK: - Helpers

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func encodedMetadata() throws -> String {
        let meta = try ScriptMetadataParser().parse(sampleSource)
        let data = try JSONEncoder.brownBear.encode(meta)
        return String(decoding: data, as: UTF8.self)
    }
}
