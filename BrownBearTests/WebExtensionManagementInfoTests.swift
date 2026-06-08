//
//  WebExtensionManagementInfoTests.swift
//  BrownBearTests
//
//  Pure-logic coverage for chrome.management ExtensionInfo mapping and chrome.permissions set
//  reconciliation: declared vs. required vs. optional permissions, contains/request/remove rules,
//  and the management record shape.
//

import XCTest
@testable import BrownBear

final class WebExtensionManagementInfoTests: XCTestCase {

    private func manifest(_ json: [String: Any]) throws -> WebExtensionManifest {
        var base: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "1.0"]
        base.merge(json) { _, new in new }
        return try WebExtensionManifest.parse(base)
    }

    private func ext(_ manifestJSON: [String: Any], id: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                     enabled: Bool = true) throws -> WebExtension {
        var base: [String: Any] = ["manifest_version": 3, "name": "Test", "version": "2.5"]
        base.merge(manifestJSON) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: base)
        return WebExtension(id: id, manifestJSON: String(decoding: data, as: UTF8.self), enabled: enabled)
    }

    // MARK: - management ExtensionInfo

    func testExtensionInfoShape() throws {
        let info = WebExtensionManagementInfo.extensionInfo(for: try ext([
            "name": "Cool Ext", "version": "3.1", "description": "does things",
            "permissions": ["tabs", "storage"], "host_permissions": ["https://example.com/*"]
        ]))
        XCTAssertEqual(info["id"] as? String, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(info["name"] as? String, "Cool Ext")
        XCTAssertEqual(info["version"] as? String, "3.1")
        XCTAssertEqual(info["description"] as? String, "does things")
        XCTAssertEqual(info["enabled"] as? Bool, true)
        XCTAssertEqual(info["type"] as? String, "extension")
        XCTAssertEqual(info["installType"] as? String, "normal")
        XCTAssertEqual(info["mayDisable"] as? Bool, true)
        XCTAssertEqual(info["isApp"] as? Bool, false)
        XCTAssertEqual((info["permissions"] as? [String])?.sorted(), ["storage", "tabs"])
        XCTAssertEqual(info["hostPermissions"] as? [String], ["https://example.com/*"])
        XCTAssertNil(info["disabledReason"], "an enabled extension has no disabledReason")
    }

    func testDisabledExtensionReportsReason() throws {
        let info = WebExtensionManagementInfo.extensionInfo(for: try ext([:], enabled: false))
        XCTAssertEqual(info["enabled"] as? Bool, false)
        XCTAssertEqual(info["disabledReason"] as? String, "unknown")
    }

    func testIconInfosSortedWithURLs() throws {
        let info = WebExtensionManagementInfo.iconInfos(for: try ext([
            "icons": ["48": "icons/48.png", "16": "icons/16.png", "128": "icons/128.png"]
        ]))
        XCTAssertEqual(info.map { $0["size"] as? Int }, [16, 48, 128])
        XCTAssertEqual(info.first?["url"] as? String,
                       "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/icons/16.png")
    }

    func testOptionsURL() throws {
        XCTAssertEqual(WebExtensionManagementInfo.optionsURL(for: try ext(["options_page": "opts.html"])),
                       "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/opts.html")
        XCTAssertEqual(WebExtensionManagementInfo.optionsURL(for: try ext([:])), "")
    }

    func testAllExtensionInfosSortedById() throws {
        let a = try ext([:], id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let b = try ext([:], id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let all = WebExtensionManagementInfo.allExtensionInfos([a, b])
        XCTAssertEqual(all.map { $0["id"] as? String },
                       ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
    }

    // MARK: - permissions reconciliation

    func testContainsRequiredManifestPermission() throws {
        let m = try manifest(["permissions": ["tabs"], "host_permissions": ["https://a.com/*"]])
        let granted = WebExtensionManagementInfo.PermissionSet()
        XCTAssertTrue(WebExtensionManagementInfo.contains(
            .init(permissions: ["tabs"], origins: ["https://a.com/*"]), manifest: m, granted: granted))
        XCTAssertFalse(WebExtensionManagementInfo.contains(
            .init(permissions: ["bookmarks"]), manifest: m, granted: granted))
    }

    func testContainsAfterGrant() throws {
        let m = try manifest(["permissions": ["tabs"], "optional_permissions": ["bookmarks"]])
        let granted = WebExtensionManagementInfo.PermissionSet(permissions: ["bookmarks"])
        XCTAssertTrue(WebExtensionManagementInfo.contains(.init(permissions: ["bookmarks"]),
                                                          manifest: m, granted: granted))
    }

    func testEmptyRequestAlwaysContains() throws {
        let m = try manifest([:])
        XCTAssertTrue(WebExtensionManagementInfo.contains(.init(), manifest: m,
                                                          granted: .init()))
    }

    func testRequestRejectsUndeclaredPermission() throws {
        let m = try manifest(["optional_permissions": ["bookmarks"]])
        // Declared optional → granted.
        XCTAssertEqual(WebExtensionManagementInfo.resolveRequest(.init(permissions: ["bookmarks"]), manifest: m),
                       .init(permissions: ["bookmarks"]))
        // Never declared → rejected (nil).
        XCTAssertNil(WebExtensionManagementInfo.resolveRequest(.init(permissions: ["history"]), manifest: m))
    }

    func testRequestAllowsAlreadyRequiredPermission() throws {
        let m = try manifest(["permissions": ["tabs"]])
        // Requesting an already-required permission is allowed (resolves to that set; still "true").
        XCTAssertEqual(WebExtensionManagementInfo.resolveRequest(.init(permissions: ["tabs"]), manifest: m),
                       .init(permissions: ["tabs"]))
    }

    func testRequestRejectsContentScriptMatchAsOrigin() throws {
        // A content_scripts.matches pattern is NOT a requestable host permission — granting it would
        // escalate inject-only access to full host access (cookies/fetch/executeScript). Must reject.
        let m = try manifest(["content_scripts": [["matches": ["https://opt.com/*"], "js": ["c.js"]]]])
        XCTAssertNil(WebExtensionManagementInfo.resolveRequest(.init(origins: ["https://opt.com/*"]), manifest: m))
    }

    func testRequestAllowsOptionalHostPermissionOrigin() throws {
        // An origin declared in optional_host_permissions IS requestable (Chrome MV3).
        let m = try manifest(["manifest_version": 3,
                              "optional_host_permissions": ["https://opt.com/*"]])
        XCTAssertEqual(WebExtensionManagementInfo.resolveRequest(.init(origins: ["https://opt.com/*"]), manifest: m),
                       .init(origins: ["https://opt.com/*"]))
        // An undeclared origin is still rejected.
        XCTAssertNil(WebExtensionManagementInfo.resolveRequest(.init(origins: ["https://evil.com/*"]), manifest: m))
    }

    func testMV2OptionalHostPatternIsRequestable() throws {
        // MV2 mixes API perms + host patterns in optional_permissions; the host pattern is requestable.
        let m = try manifest(["manifest_version": 2,
                              "optional_permissions": ["bookmarks", "https://opt.com/*"]])
        XCTAssertEqual(WebExtensionManagementInfo.resolveRequest(.init(origins: ["https://opt.com/*"]), manifest: m),
                       .init(origins: ["https://opt.com/*"]))
        XCTAssertEqual(WebExtensionManagementInfo.resolveRequest(.init(permissions: ["bookmarks"]), manifest: m),
                       .init(permissions: ["bookmarks"]))
    }

    func testRemoveRejectsRequiredPermission() throws {
        let m = try manifest(["permissions": ["tabs"], "optional_permissions": ["bookmarks"]])
        let granted = WebExtensionManagementInfo.PermissionSet(permissions: ["bookmarks"])
        // Removing the runtime-granted optional one succeeds, leaving nothing.
        XCTAssertEqual(WebExtensionManagementInfo.resolveRemove(.init(permissions: ["bookmarks"]),
                                                               manifest: m, granted: granted),
                       .init())
        // Removing a required manifest permission is rejected.
        XCTAssertNil(WebExtensionManagementInfo.resolveRemove(.init(permissions: ["tabs"]),
                                                              manifest: m, granted: granted))
    }

    func testGetAllReturnsSortedDeclaredAndGranted() throws {
        let m = try manifest(["permissions": ["tabs"], "host_permissions": ["https://a.com/*"]])
        let effective = WebExtensionManagementInfo.effective(
            manifest: m, granted: .init(permissions: ["bookmarks"], origins: ["https://b.com/*"]))
        XCTAssertEqual(effective.permissions.sorted(), ["bookmarks", "tabs"])
        XCTAssertEqual(effective.origins.sorted(), ["https://a.com/*", "https://b.com/*"])
    }

    func testPermissionSetPayloadParsing() {
        let set = WebExtensionManagementInfo.PermissionSet(payload: [
            "permissions": ["tabs", "storage"], "origins": ["https://x.com/*"]
        ])
        XCTAssertEqual(set.permissions, ["tabs", "storage"])
        XCTAssertEqual(set.origins, ["https://x.com/*"])
        XCTAssertEqual(set.dictionary["permissions"] as? [String], ["storage", "tabs"])
    }
}
