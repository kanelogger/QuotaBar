import Foundation
import XCTest
@testable import QuotaCore

final class RemoteProbeParsingTests: XCTestCase {
    func testKimiParsesWeeklyAndFiveHourUsage() async throws {
        let data = try fixture("kimi-usage")

        let metrics = try KimiUsageProbe.parseUsage(data)

        XCTAssertEqual(try XCTUnwrap(metrics.first(where: { $0.window == .weekly })?.percentRemaining), 1834.0 / 2048.0 * 100.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metrics.first(where: { $0.window == .fiveHour })?.percentRemaining), 75, accuracy: 0.001)
        XCTAssertNil(metrics.first(where: { $0.window == .monthly }))
        let monthly = try await UnavailableKimiMonthlyProbe().fetchMonthlyMetric(token: "redacted")
        XCTAssertEqual(monthly.availability, .unavailable)
    }

    func testDeepSeekParsesEveryCurrencyAndRejectsMalformedBalance() throws {
        let valid = try fixture("deepseek-balance")
        let balance = try DeepSeekProbe.parseBalance(valid)
        let metrics = balance.metrics
        XCTAssertTrue(balance.isAvailable)
        XCTAssertEqual(metrics.map(\.unit), ["CNY", "USD"])
        XCTAssertEqual(metrics.compactMap(\.remaining), [10.5, 2.25])
        XCTAssertEqual(metrics.first?.balanceAmount, Decimal(string: "10.50"))

        let malformed = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"oops","granted_balance":"0","topped_up_balance":"0"}]}"#.utf8)
        XCTAssertThrowsError(try DeepSeekProbe.parseBalance(malformed))
        let negative = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"-0.01"}]}"#.utf8)
        XCTAssertThrowsError(try DeepSeekProbe.parseBalance(negative))
    }

    func testCodexUsesSecondaryRateLimitAndTTYFallbackParser() throws {
        let data = try fixture("codex-rate-limits")
        let metric = try CodexProbe.parseRPCResponse(data)
        XCTAssertEqual(metric.window, .weekly)
        XCTAssertEqual(metric.percentRemaining, 35)

        let tty = "Weekly limit\n████ 42% left\nresets in 2d 4h"
        XCTAssertEqual(try CodexProbe.parseTTY(tty).percentRemaining, 42)
    }

    func testCodexAcceptsCurrentSingleWeeklyPrimaryWindow() throws {
        let data = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":1784785035},"secondary":null}}}"#.utf8)

        XCTAssertEqual(try CodexProbe.parseRPCResponse(data).percentRemaining, 37)
    }

    func testCodexRejectsNonweeklyPrimaryAndRecognizesLoggedOutTTY() {
        let hourly = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300},"secondary":null}}}"#.utf8)

        XCTAssertThrowsError(try CodexProbe.parseRPCResponse(hourly))
        XCTAssertThrowsError(try CodexProbe.parseTTY("Please log in to continue"))
    }

    private func fixture(_ name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: RemoteProbeParsingTests.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
