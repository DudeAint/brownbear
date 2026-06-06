//
//  BackgroundStoresTests.swift
//  BrownBearTests
//
//  Persistence + capping for the background stores. The schedule-state round-trip test guards
//  the encode/decode key-type bug that would otherwise silently reset every schedule on a
//  background cold-start.
//

import XCTest
@testable import BrownBear

final class ScheduleStateStoreTests: XCTestCase {

    func testSurvivesAcrossInstances() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-sched-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let scriptID = UUID()
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        let next = last.addingTimeInterval(3600)

        let writer = ScheduleStateStore(fileURL: url)
        await writer.record(scriptID: scriptID, lastFire: last, nextFire: next)

        // A fresh instance over the same file — simulates a background cold-start.
        let reader = ScheduleStateStore(fileURL: url)
        let reloadedLast = await reader.lastFire(for: scriptID)
        let earliest = await reader.earliestNextFire()
        XCTAssertEqual(reloadedLast, last, "lastFire must survive a reload")
        XCTAssertEqual(earliest, next, "nextFire must survive a reload")
    }
}

final class LogStoreTests: XCTestCase {

    func testCapsToCapacityKeepingNewest() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-logs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LogStore(fileURL: url, capacity: 5)
        for index in 0..<12 {
            await store.append(LogEntry(scriptID: nil, message: "m\(index)"))
        }
        let recent = await store.recent(limit: 100)
        XCTAssertEqual(recent.count, 5, "should cap at capacity")
        XCTAssertEqual(recent.first?.message, "m11", "newest first")
        XCTAssertEqual(recent.last?.message, "m7", "oldest retained is the 5th-from-last")
    }
}
