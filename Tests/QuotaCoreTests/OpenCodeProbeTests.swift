import Foundation
import XCTest
@testable import QuotaCore

final class OpenCodeProbeTests: XCTestCase {
    func testPercentRemainingClampsAtBounds() {
        XCTAssertEqual(UsageMetric.quota(id: "test", name: "", window: .fiveHour, used: -1, total: 12).percentRemaining, 100)
        XCTAssertEqual(UsageMetric.quota(id: "test", name: "", window: .fiveHour, used: 18, total: 12).percentRemaining, 0)
        XCTAssertEqual(UsageMetric.quota(id: "test", name: "", window: .fiveHour, used: 6, total: 12).percentRemaining, 50)
    }

    func testSQLFiltersOpenCodeGoAssistantCostRows() {
        let sql = OpenCodeProbe.primarySQL(fiveHourStartMilliseconds: 100, weekStartMilliseconds: 200)
        XCTAssertTrue(sql.contains("json_extract(data, '$.providerID') = 'opencode-go'"))
        XCTAssertTrue(sql.contains("json_extract(data, '$.role') = 'assistant'"))
        XCTAssertTrue(sql.contains("json_type(data, '$.cost') IN ('integer', 'real')"))
    }

    func testAnchoredMonthUsesOriginalDayAndRollsBackWhenNeeded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 1, day: 20, hour: 9))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 12))!

        let bounds = OpenCodeProbe.anchoredMonthBounds(now: now, anchor: anchor)
        let start = calendar.dateComponents([.month, .day, .hour], from: bounds.start)
        let end = calendar.dateComponents([.month, .day, .hour], from: bounds.end)

        XCTAssertEqual(start.month, 3)
        XCTAssertEqual(start.day, 20)
        XCTAssertEqual(start.hour, 9)
        XCTAssertEqual(end.month, 4)
        XCTAssertEqual(end.day, 20)
    }

    func testAnchoredMonthClampsDayWithoutDriftingAcrossShortMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 9))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 12))!

        let bounds = OpenCodeProbe.anchoredMonthBounds(now: now, anchor: anchor)
        let start = calendar.dateComponents([.month, .day], from: bounds.start)
        let end = calendar.dateComponents([.month, .day], from: bounds.end)

        XCTAssertEqual(start.month, 2)
        XCTAssertEqual(start.day, 28)
        XCTAssertEqual(end.month, 3)
        XCTAssertEqual(end.day, 31)
    }

    func testUTCWeekStartsMondayAndEndsSevenDaysLater() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sunday = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 19,
            hour: 23,
            minute: 59
        ))!

        let start = OpenCodeProbe.startOfWeekUTC(from: sunday)
        let end = OpenCodeProbe.endOfWeekUTC(from: sunday)
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: start)

        XCTAssertEqual(parts.weekday, 2)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 86_400)
    }
}
