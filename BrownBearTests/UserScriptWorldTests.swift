//
//  UserScriptWorldTests.swift
//  BrownBearTests
//
//  The pure world-override mapping behind the "Userscript world" setting: it rewrites the world a
//  userscript manager registered a script with into the world BrownBear actually runs it in.
//

import XCTest
@testable import BrownBear

final class UserScriptWorldTests: XCTestCase {

    func testUserScriptForcesMainIntoIsolated() {
        let s = UserScriptWorld.userScript
        XCTAssertEqual(s.effectiveWorld(registered: "MAIN"), "USER_SCRIPT", "a page-world script is pulled into the sandbox")
        XCTAssertEqual(s.effectiveWorld(registered: "main"), "USER_SCRIPT", "case-insensitive")
        // Already-isolated worlds are left exactly as registered.
        XCTAssertEqual(s.effectiveWorld(registered: "USER_SCRIPT"), "USER_SCRIPT")
        XCTAssertEqual(s.effectiveWorld(registered: "ISOLATED"), "ISOLATED")
        XCTAssertEqual(s.effectiveWorld(registered: ""), "")
    }

    func testManagerInfraBrokerKeepsMainEvenWhenSandboxed() {
        // The manager's OWN MAIN-world infra broker (e.g. ScriptCat's "scriptcat-inject") must reach the
        // page MAIN world to set the manager up — like Violentmonkey's broker — so it is exempt from the
        // isolated remap, while the user's own page-world scripts stay sandboxed (immune to page breakage).
        let s = UserScriptWorld.userScript
        XCTAssertEqual(s.effectiveWorld(registered: "MAIN", scriptId: "scriptcat-inject"), "MAIN",
                       "the manager's infra broker keeps the page MAIN world")
        XCTAssertEqual(s.effectiveWorld(registered: "MAIN", scriptId: "user-uuid-123"), "USER_SCRIPT",
                       "a user's own page-world script is still pulled into the sandbox")
        // A non-MAIN broker registration is untouched; the exemption only matters for MAIN.
        XCTAssertEqual(s.effectiveWorld(registered: "USER_SCRIPT", scriptId: "scriptcat-inject"), "USER_SCRIPT")
    }

    func testAllIsolatedPullsEvenTheBrokerIntoOneWorld() {
        // Unlike `.userScript`, the "All Isolated" mode does NOT exempt the manager's infra broker: every
        // MAIN registration — the broker included — is remapped to the isolated world, so the manager's whole
        // runtime (inject + content + scripting + bodies) shares ONE WKContentWorld and its cross-context bus
        // never crosses worlds. This is the single-world config some ScriptCat scripts need.
        let s = UserScriptWorld.allIsolated
        XCTAssertEqual(s.effectiveWorld(registered: "MAIN", scriptId: "scriptcat-inject"), "USER_SCRIPT",
                       "the broker is pulled into the isolated world too (no carve-out)")
        XCTAssertEqual(s.effectiveWorld(registered: "MAIN", scriptId: "user-uuid-123"), "USER_SCRIPT")
        XCTAssertEqual(s.effectiveWorld(registered: "main"), "USER_SCRIPT", "case-insensitive")
        // Already-isolated worlds pass through unchanged.
        XCTAssertEqual(s.effectiveWorld(registered: "USER_SCRIPT", scriptId: "scriptcat-inject"), "USER_SCRIPT")
        XCTAssertEqual(s.effectiveWorld(registered: "ISOLATED"), "ISOLATED")
        XCTAssertEqual(s.effectiveWorld(registered: ""), "")
    }

    func testManagerRuntimeAutoCollapsesToAllIsolatedUnderTheDefault() {
        // A userscript manager (registers a broker) defaults to All-Isolated so its fragile multi-world
        // runtime just works (no toggle); an explicit choice is honored; a non-manager keeps the setting.
        XCTAssertEqual(UserScriptWorld.resolved(forManagerRuntime: true, configured: .managerChoice), .allIsolated,
                       "a manager on the default auto-collapses to one isolated world")
        XCTAssertEqual(UserScriptWorld.resolved(forManagerRuntime: false, configured: .managerChoice), .managerChoice,
                       "a non-manager extension is untouched")
        for explicit: UserScriptWorld in [.main, .userScript, .allIsolated] {
            XCTAssertEqual(UserScriptWorld.resolved(forManagerRuntime: true, configured: explicit), explicit,
                           "an explicit world choice always wins, even for a manager")
        }
    }

    func testMainForcesEverythingToMain() {
        let s = UserScriptWorld.main
        XCTAssertEqual(s.effectiveWorld(registered: "USER_SCRIPT"), "MAIN")
        XCTAssertEqual(s.effectiveWorld(registered: "ISOLATED"), "MAIN")
        XCTAssertEqual(s.effectiveWorld(registered: "MAIN"), "MAIN")
        XCTAssertEqual(s.effectiveWorld(registered: ""), "MAIN")
    }

    func testManagerChoiceIsIdentity() {
        let s = UserScriptWorld.managerChoice
        for world in ["MAIN", "USER_SCRIPT", "ISOLATED", ""] {
            XCTAssertEqual(s.effectiveWorld(registered: world), world, "manager's choice is honored verbatim")
        }
    }

    func testDefaultIsManagerChoice() {
        // The setting accessor defaults to honoring the manager's registered world (Violentmonkey parity:
        // TM/ScriptCat normal userscripts register MAIN → run in the page world, like VM).
        let key = AppSettings.Key.userScriptWorld
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AppSettings.userScriptWorld, .managerChoice, "default honors the manager's world like VM")
        // A manager's MAIN-registered userscript reaches the page world under the default; @inject-into
        // content stays isolated — exactly what makes TM/SC behave like Violentmonkey.
        XCTAssertEqual(AppSettings.userScriptWorld.effectiveWorld(registered: "MAIN", scriptId: "some-uuid"), "MAIN")
        XCTAssertEqual(AppSettings.userScriptWorld.effectiveWorld(registered: "USER_SCRIPT", scriptId: "some-uuid"), "USER_SCRIPT")
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
    }

    func testRawValuesRoundTripForAppStorage() {
        // The SwiftUI Picker stores the rawValue; every case must reconstruct from it.
        for world in UserScriptWorld.allCases {
            XCTAssertEqual(UserScriptWorld(rawValue: world.rawValue), world)
        }
    }
}
