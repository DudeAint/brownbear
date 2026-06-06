//
//  CrontabScheduleTests.swift
//  BrownBearTests
//
//  Table-driven tests for crontab parsing, next-fire computation, and due-evaluation, including
//  the day-of-month/day-of-week quirk, @every intervals, once-only, and per-unit `once` dedup.
//

import XCTest
@testable import BrownBear

final class CrontabScheduleTests: XCTestCase {

    private let calendar = Calendar.gregorianUTC

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return calendar.date(from: comps)!
    }

    private func components(_ date: Date) -> (h: Int, m: Int, weekday: Int) {
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        return (c.hour!, c.minute!, c.weekday! - 1)
    }

    // MARK: - Parsing

    func testRejectsMalformed() {
        XCTAssertNil(CrontabSchedule.parse(""))
        XCTAssertNil(CrontabSchedule.parse("* * *"))           // too few fields
        XCTAssertNil(CrontabSchedule.parse("99 * * * *"))      // minute out of range
        XCTAssertNil(CrontabSchedule.parse("* 25 * * *"))      // hour out of range
    }

    func testParsesSixFieldByDroppingSeconds() {
        // "30 0 9 * * *" (sec min hour …) → treat as "0 9 * * *".
        guard let schedule = CrontabSchedule.parse("30 0 9 * * *") else { return XCTFail("parse failed") }
        let next = schedule.nextFireDate(after: date(2026, 6, 15, 10, 0), calendar: calendar)
        XCTAssertEqual(next, date(2026, 6, 16, 9, 0))
    }

    // MARK: - nextFireDate

    func testStepMinutes() {
        let schedule = CrontabSchedule.parse("*/15 * * * *")!
        XCTAssertEqual(schedule.nextFireDate(after: date(2026, 1, 1, 0, 7), calendar: calendar),
                       date(2026, 1, 1, 0, 15))
        XCTAssertEqual(schedule.nextFireDate(after: date(2026, 1, 1, 0, 15), calendar: calendar),
                       date(2026, 1, 1, 0, 30))
    }

    func testDailyRollsToNextDay() {
        let schedule = CrontabSchedule.parse("30 2 * * *")!
        XCTAssertEqual(schedule.nextFireDate(after: date(2026, 6, 15, 3, 0), calendar: calendar),
                       date(2026, 6, 16, 2, 30))
    }

    func testYearlyRollsAcrossMonths() {
        let schedule = CrontabSchedule.parse("0 0 1 1 *")!
        XCTAssertEqual(schedule.nextFireDate(after: date(2026, 6, 15, 12, 0), calendar: calendar),
                       date(2027, 1, 1, 0, 0))
    }

    func testWeekdayRangeFiresOnAWeekdayAtTime() {
        let schedule = CrontabSchedule.parse("0 9 * * 1-5")!
        let next = schedule.nextFireDate(after: date(2026, 1, 3, 10, 0), calendar: calendar)!
        let parts = components(next)
        XCTAssertEqual(parts.h, 9)
        XCTAssertEqual(parts.m, 0)
        XCTAssertTrue((1...5).contains(parts.weekday), "weekday \(parts.weekday) should be Mon–Fri")
        XCTAssertGreaterThan(next, date(2026, 1, 3, 10, 0))
    }

    func testSundayAsSeven() {
        let schedule = CrontabSchedule.parse("0 0 * * 7")!
        let next = schedule.nextFireDate(after: date(2026, 1, 1, 0, 0), calendar: calendar)!
        XCTAssertEqual(components(next).weekday, 0) // Sunday
    }

    // MARK: - isDue

    func testEveryInterval() {
        let schedule = CrontabSchedule.parse("@every 30m")!
        let now = date(2026, 1, 1, 12, 0)
        XCTAssertTrue(schedule.isDue(now: now, lastFire: now.addingTimeInterval(-31 * 60), calendar: calendar))
        XCTAssertFalse(schedule.isDue(now: now, lastFire: now.addingTimeInterval(-29 * 60), calendar: calendar))
        XCTAssertTrue(schedule.isDue(now: now, lastFire: nil, calendar: calendar))
    }

    func testOnceEver() {
        let schedule = CrontabSchedule.parse("once")!
        XCTAssertTrue(schedule.isDue(now: Date(), lastFire: nil, calendar: calendar))
        XCTAssertFalse(schedule.isDue(now: Date(), lastFire: Date(), calendar: calendar))
    }

    func testCronIsDueAcrossMissedFires() {
        let schedule = CrontabSchedule.parse("*/5 * * * *")!
        // last ran 00:03, now 00:10 → a fire at 00:05 happened → due.
        XCTAssertTrue(schedule.isDue(now: date(2026, 1, 1, 0, 10),
                                     lastFire: date(2026, 1, 1, 0, 3), calendar: calendar))
        // last ran 00:08, now 00:09 → next fire is 00:10 (future) → not due.
        XCTAssertFalse(schedule.isDue(now: date(2026, 1, 1, 0, 9),
                                      lastFire: date(2026, 1, 1, 0, 8), calendar: calendar))
    }

    func testOncePerUnitDedup() {
        // "once" in the hour position → at most once per hour.
        let schedule = CrontabSchedule.parse("* once * * *")!
        // Already ran earlier this same hour → not due again.
        XCTAssertFalse(schedule.isDue(now: date(2026, 1, 1, 5, 30),
                                      lastFire: date(2026, 1, 1, 5, 2), calendar: calendar))
        // Last run was the previous hour → due.
        XCTAssertTrue(schedule.isDue(now: date(2026, 1, 1, 5, 30),
                                     lastFire: date(2026, 1, 1, 4, 59), calendar: calendar))
    }
}
