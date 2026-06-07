//
//  WebExtensionContextMenuStoreTests.swift
//  BrownBearTests
//
//  Table-driven coverage for the chrome.contextMenus store's pure logic: context + URL-pattern
//  matching (applicableTree), parent/child trees, remove() taking the subtree, radio sibling
//  clearing, checkbox toggling, the fail-closed sanitizers (unknown type → normal, unknown context
//  dropped → default page, self/unknown/cyclic parent → root), per-extension namespacing, and the
//  OnClickData shape.
//

import XCTest
@testable import BrownBear

@MainActor
final class WebExtensionContextMenuStoreTests: XCTestCase {

    private let ext = "abcdefghijklmnopabcdefghijklmnop"
    private let other = "ponmlkjihgfedcbaponmlkjihgfedcba"

    private func makeStore() -> WebExtensionContextMenuStore { WebExtensionContextMenuStore() }

    func testCreateReturnsSuppliedID() throws {
        let store = makeStore()
        let id = try store.create(extensionID: ext, properties: ["id": "save", "title": "Save"])
        XCTAssertEqual(id, "save")
        XCTAssertEqual(store.item(extensionID: ext, id: "save")?.title, "Save")
    }

    func testDuplicateIDThrows() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "x", "title": "X"])
        XCTAssertThrowsError(try store.create(extensionID: ext, properties: ["id": "x", "title": "Y"]))
    }

    func testUnknownTypeAndContextsFailClosed() throws {
        let store = makeStore()
        let id = try store.create(extensionID: ext, properties: [
            "title": "T", "type": "bogus", "contexts": ["nonsense", "page"]
        ])
        let item = try XCTUnwrap(store.item(extensionID: ext, id: id))
        XCTAssertEqual(item.type, .normal)             // unknown type → normal
        XCTAssertEqual(item.contexts, ["page"])        // unknown context dropped, page kept
    }

    func testContextsDefaultsToPageWhenEmpty() throws {
        let store = makeStore()
        let id = try store.create(extensionID: ext, properties: ["title": "T", "contexts": ["onlybogus"]])
        XCTAssertEqual(store.item(extensionID: ext, id: id)?.contexts, ["page"])
    }

    func testApplicableTreeMatchesPageContext() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "p", "title": "Page", "contexts": ["page"]])
        _ = try store.create(extensionID: ext, properties: ["id": "l", "title": "Link", "contexts": ["link"]])
        // A page press (no link) shows the page item but not the link-only item.
        let pageOnly = store.applicableTree(extensionID: ext, pageURL: "https://x.com/", linkURL: nil, contexts: ["page"])
        XCTAssertEqual(pageOnly.map(\.item.id), ["p"])
        // A link press shows both (page items also apply on links, like Chrome).
        let onLink = store.applicableTree(extensionID: ext, pageURL: "https://x.com/", linkURL: "https://t.com/a", contexts: ["page", "link"])
        XCTAssertEqual(Set(onLink.map(\.item.id)), ["p", "l"])
    }

    func testDocumentURLPatternsGateOnPage() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: [
            "id": "only", "title": "Only", "documentUrlPatterns": ["*://example.com/*"]
        ])
        XCTAssertTrue(store.applicableTree(extensionID: ext, pageURL: "https://example.com/p", linkURL: nil, contexts: ["page"]).isEmpty == false)
        XCTAssertTrue(store.applicableTree(extensionID: ext, pageURL: "https://other.com/p", linkURL: nil, contexts: ["page"]).isEmpty)
    }

    func testTargetURLPatternsGateOnLink() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: [
            "id": "img", "title": "T", "contexts": ["link"], "targetUrlPatterns": ["*://cdn.com/*"]
        ])
        XCTAssertFalse(store.applicableTree(extensionID: ext, pageURL: "https://x.com/", linkURL: "https://cdn.com/a.png", contexts: ["page", "link"]).isEmpty)
        XCTAssertTrue(store.applicableTree(extensionID: ext, pageURL: "https://x.com/", linkURL: "https://nope.com/a.png", contexts: ["page", "link"]).isEmpty)
    }

    func testParentChildTreeAndCycleRejected() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "root", "title": "Root"])
        _ = try store.create(extensionID: ext, properties: ["id": "child", "title": "Child", "parentId": "root"])
        // A parent pointing at a non-existent id is dropped to root.
        _ = try store.create(extensionID: ext, properties: ["id": "orphan", "title": "Orphan", "parentId": "ghost"])
        let tree = store.applicableTree(extensionID: ext, pageURL: "https://x.com/", linkURL: nil, contexts: ["page"])
        let root = try XCTUnwrap(tree.first { $0.item.id == "root" })
        XCTAssertEqual(root.children.map(\.item.id), ["child"])
        XCTAssertNil(store.item(extensionID: ext, id: "orphan")?.parentID)   // ghost parent → root
    }

    func testRemoveTakesSubtree() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "a", "title": "A"])
        _ = try store.create(extensionID: ext, properties: ["id": "b", "title": "B", "parentId": "a"])
        _ = try store.create(extensionID: ext, properties: ["id": "c", "title": "C", "parentId": "b"])
        try store.remove(extensionID: ext, id: "a")
        XCTAssertNil(store.item(extensionID: ext, id: "a"))
        XCTAssertNil(store.item(extensionID: ext, id: "b"))
        XCTAssertNil(store.item(extensionID: ext, id: "c"))
    }

    func testRadioSelectionClearsSiblings() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "r1", "title": "1", "type": "radio", "checked": true])
        _ = try store.create(extensionID: ext, properties: ["id": "r2", "title": "2", "type": "radio"])
        store.applyClickStateChange(extensionID: ext, id: "r2")
        XCTAssertEqual(store.item(extensionID: ext, id: "r2")?.checked, true)
        XCTAssertEqual(store.item(extensionID: ext, id: "r1")?.checked, false)
    }

    func testCheckboxToggles() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "c", "title": "C", "type": "checkbox"])
        XCTAssertEqual(store.applyClickStateChange(extensionID: ext, id: "c"), true)
        XCTAssertEqual(store.applyClickStateChange(extensionID: ext, id: "c"), false)
    }

    func testRemoveAllAndForgetAreNamespaced() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "a", "title": "A"])
        _ = try store.create(extensionID: other, properties: ["id": "b", "title": "B"])
        store.removeAll(extensionID: ext)
        XCTAssertNil(store.item(extensionID: ext, id: "a"))
        XCTAssertNotNil(store.item(extensionID: other, id: "b"))   // other extension untouched
        store.forgetExtension(other)
        XCTAssertNil(store.item(extensionID: other, id: "b"))
    }

    func testOnClickDataShape() throws {
        let store = makeStore()
        _ = try store.create(extensionID: ext, properties: ["id": "c", "title": "C", "type": "checkbox", "contexts": ["link"]])
        let item = try XCTUnwrap(store.item(extensionID: ext, id: "c"))
        let info = store.onClickData(item: item, pageURL: "https://x.com/p", linkURL: "https://t.com/a")
        XCTAssertEqual(info["menuItemId"] as? String, "c")
        XCTAssertEqual(info["editable"] as? Bool, false)
        XCTAssertEqual(info["pageUrl"] as? String, "https://x.com/p")
        XCTAssertEqual(info["linkUrl"] as? String, "https://t.com/a")
        XCTAssertEqual(info["wasChecked"] as? Bool, false)
        XCTAssertEqual(info["checked"] as? Bool, true)   // a tap would check it
    }
}
