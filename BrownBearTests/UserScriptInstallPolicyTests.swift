//
//  UserScriptInstallPolicyTests.swift
//  BrownBearTests
//
//  The pure decision table that drives `.user.js` routing: given the user's install-target policy and how
//  many installed managers claim the URL, what the navigation delegate does (native card / picker /
//  route to the single manager). Keeping it pure makes the routing code a thin switch.
//

import XCTest
@testable import BrownBear

final class UserScriptInstallPolicyTests: XCTestCase {

    func testAlwaysBrownBearIgnoresManagers() {
        for count in 0...3 {
            XCTAssertEqual(UserScriptInstallPolicy.brownBear.decision(managerCount: count), .nativeCard,
                           "always-BrownBear shows the native card regardless of managers (count \(count))")
        }
    }

    func testAskShowsNativeCardWithNoManagersAndPickerOtherwise() {
        XCTAssertEqual(UserScriptInstallPolicy.ask.decision(managerCount: 0), .nativeCard)
        XCTAssertEqual(UserScriptInstallPolicy.ask.decision(managerCount: 1), .picker(showNativeInstall: true))
        XCTAssertEqual(UserScriptInstallPolicy.ask.decision(managerCount: 2), .picker(showNativeInstall: true))
    }

    func testAlwaysExtensionRoutesSingleAndPicksAmongManagersOnly() {
        XCTAssertEqual(UserScriptInstallPolicy.alwaysExtension.decision(managerCount: 0), .nativeCard,
                       "no manager claims it → fall back to BrownBear")
        XCTAssertEqual(UserScriptInstallPolicy.alwaysExtension.decision(managerCount: 1), .routeToSingleManager)
        XCTAssertEqual(UserScriptInstallPolicy.alwaysExtension.decision(managerCount: 3),
                       .picker(showNativeInstall: false),
                       "several managers → pick among extensions only, no BrownBear option")
    }

    func testRawValueRoundTripAndDefault() {
        for policy in UserScriptInstallPolicy.allCases {
            XCTAssertEqual(UserScriptInstallPolicy(rawValue: policy.rawValue), policy)
            XCTAssertFalse(policy.title.isEmpty)
        }
        XCTAssertNil(UserScriptInstallPolicy(rawValue: "nonsense"))
    }
}
