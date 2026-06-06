//
//  BughuntRegressionTests.swift
//  BrownBearTests
//
//  Locks in fixes from the deep adversarial bug hunt: the cron first-fire catch-up window, the
//  @connect redirect guard (allowlist + cross-host credential stripping), and ephemeral
//  chrome.storage.session.
//

import XCTest
@testable import BrownBear

final class BughuntRegressionTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 6
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return calendar.date(from: comps)!
    }

    // MARK: - #3 cron first-fire catch-up

    func testCronCatchesFirstFireWhenWokenLate() throws {
        let schedule = try XCTUnwrap(CrontabSchedule.parse("0 9 * * *"))   // 09:00 daily
        let calendar = utc
        let now = date(10, 0, calendar: calendar)        // an hour past the 09:00 schedule
        let installed = date(0, 0, calendar: calendar)   // installed at midnight, before 09:00

        // Never fired + woken late: eligibleSince (install time) lets it catch the missed 09:00 fire.
        XCTAssertTrue(schedule.isDue(now: now, lastFire: nil, eligibleSince: installed, calendar: calendar))
        // The old behavior (only a now−60s window) would have missed it entirely.
        XCTAssertFalse(schedule.isDue(now: now, lastFire: nil, eligibleSince: nil, calendar: calendar))
        // Already ran at 09:00 today → not due again.
        XCTAssertFalse(schedule.isDue(now: now, lastFire: date(9, 0, calendar: calendar),
                                      eligibleSince: installed, calendar: calendar))
    }

    // MARK: - #1/#8/#17 @connect redirect guard

    func testConnectAllowlistRefusesUndeclaredRedirectHost() {
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "api.allowed.com", connects: ["allowed.com"], pageHost: nil))
        XCTAssertTrue(GMNetworkService.isConnectAllowed(host: "allowed.com", connects: ["allowed.com"], pageHost: nil))
        // The redirect target a 302 would bounce to — must be refused.
        XCTAssertFalse(GMNetworkService.isConnectAllowed(host: "attacker.com", connects: ["allowed.com"], pageHost: nil))
    }

    func testRedirectGuardStripsCredentialsCrossHostOnly() {
        let fromAllowed = URLRequest(url: URL(string: "https://api.allowed.com/x")!)

        var crossHost = URLRequest(url: URL(string: "https://attacker.com/x")!)
        crossHost.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        crossHost.setValue("sid=abc", forHTTPHeaderField: "Cookie")
        let stripped = GMRedirectGuard.stripSensitiveHeadersIfCrossHost(crossHost, from: fromAllowed)
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(stripped.value(forHTTPHeaderField: "Cookie"))

        var sameHost = URLRequest(url: URL(string: "https://api.allowed.com/z")!)
        sameHost.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let kept = GMRedirectGuard.stripSensitiveHeadersIfCrossHost(sameHost, from: fromAllowed)
        XCTAssertEqual(kept.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    // MARK: - #13 ephemeral chrome.storage.session

    func testSessionStorageIsEphemeralAcrossLaunches() async {
        let suite = "brownbear.webext.sessiontest.\(UUID().uuidString)"
        let storage = WebExtensionStorage(suiteName: suite)
        await storage.set(extensionID: "e", area: .session, items: ["k": "1"])
        await storage.set(extensionID: "e", area: .local, items: ["k": "2"])

        let live = await storage.get(extensionID: "e", area: .session, keys: nil)
        XCTAssertEqual(live["k"], "1")   // readable within the same launch

        // A fresh instance over the same suite simulates a relaunch.
        let relaunched = WebExtensionStorage(suiteName: suite)
        let session = await relaunched.get(extensionID: "e", area: .session, keys: nil)
        XCTAssertTrue(session.isEmpty, "chrome.storage.session must not survive a relaunch")
        let local = await relaunched.get(extensionID: "e", area: .local, keys: nil)
        XCTAssertEqual(local["k"], "2", "chrome.storage.local must persist")
    }
}
