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

    func testDefaultIsUserScriptWorld() {
        // The setting accessor defaults to the isolated world when unset.
        let key = AppSettings.Key.userScriptWorld
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AppSettings.userScriptWorld, .userScript, "default is the isolated user-script world")
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
    }

    func testRawValuesRoundTripForAppStorage() {
        // The SwiftUI Picker stores the rawValue; every case must reconstruct from it.
        for world in UserScriptWorld.allCases {
            XCTAssertEqual(UserScriptWorld(rawValue: world.rawValue), world)
        }
    }
}
