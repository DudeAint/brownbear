//
//  WebExtensionTabRegistryTests.swift
//  BrownBearTests
//
//  The UUID(Tab) ↔ Int(chrome tab id) map behind chrome.tabs: ids are stable for a tab's lifetime,
//  unique across tabs, reversible, and a forgotten (closed) tab's id stops resolving.
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionTabRegistryTests: XCTestCase {

    func testIdsAreStableAndUnique() {
        let registry = WebExtensionTabRegistry()
        let a = UUID(), b = UUID()
        let idA = registry.id(for: a)
        XCTAssertEqual(registry.id(for: a), idA, "the same tab keeps its id")
        let idB = registry.id(for: b)
        XCTAssertNotEqual(idA, idB)
        XCTAssertEqual(registry.uuid(for: idA), a)
        XCTAssertEqual(registry.uuid(for: idB), b)
    }

    func testUnknownIdResolvesNil() {
        let registry = WebExtensionTabRegistry()
        XCTAssertNil(registry.uuid(for: 4242))
    }

    func testForgetDropsMappingAndMintsFreshIdLater() {
        let registry = WebExtensionTabRegistry()
        let a = UUID()
        let idA = registry.id(for: a)
        registry.forget(uuid: a)
        XCTAssertNil(registry.uuid(for: idA), "a closed tab's id no longer resolves")
        let idA2 = registry.id(for: a)
        XCTAssertNotEqual(idA, idA2, "re-registering mints a new id, never reusing the retired one")
    }
}
