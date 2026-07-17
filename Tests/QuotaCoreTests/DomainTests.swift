import Foundation
import XCTest
@testable import QuotaCore

final class DomainTests: XCTestCase {
    func testQuotaSummarySelectsSmallestRemainingMetric() throws {
        let openCode = ProviderSnapshot(
            providerID: .openCodeGo,
            metrics: [.quota(id: "weekly", name: "Weekly", window: .weekly, used: 21, total: 30)],
            capturedAt: Date(),
            source: "test"
        )
        let kimi = ProviderSnapshot(
            providerID: .kimi,
            metrics: [.quota(id: "five-hour", name: "5 hours", window: .fiveHour, used: 40, total: 100)],
            capturedAt: Date(),
            source: "test"
        )

        let summary = QuotaSummary.make(
            snapshots: [.openCodeGo: openCode, .kimi: kimi],
            thresholds: .defaults
        )

        XCTAssertEqual(summary?.providerID, .openCodeGo)
        XCTAssertEqual(try XCTUnwrap(summary).score, 30, accuracy: 0.001)
        XCTAssertEqual(summary?.displayValue, "30%")
    }

    func testDeepSeekBalanceUsesConfiguredCurrencyThreshold() throws {
        let deepSeek = ProviderSnapshot(
            providerID: .deepSeek,
            metrics: [.balance(currency: "CNY", amount: 5)],
            capturedAt: Date(),
            source: "test"
        )

        let summary = QuotaSummary.make(
            snapshots: [.deepSeek: deepSeek],
            thresholds: BalanceThresholds(cny: 10, usd: 2)
        )

        XCTAssertEqual(try XCTUnwrap(summary).score, 50, accuracy: 0.001)
        XCTAssertEqual(summary?.displayValue, "¥5.00")
    }

    func testUnavailableMetricsAreExcludedFromSummary() {
        let snapshot = ProviderSnapshot(
            providerID: .kimi,
            metrics: [.unavailable(id: "monthly", name: "Monthly", window: .monthly, message: "Unavailable")],
            capturedAt: Date(),
            source: "test"
        )

        XCTAssertNil(QuotaSummary.make(snapshots: [.kimi: snapshot], thresholds: .defaults))
    }

    func testUnavailableProviderIsExcludedEvenWhenItHasBalances() {
        let snapshot = ProviderSnapshot(
            providerID: .deepSeek,
            metrics: [.balance(currency: "CNY", amount: 100)],
            capturedAt: Date(),
            source: "test",
            status: .unavailable("Account disabled")
        )

        XCTAssertNil(QuotaSummary.make(snapshots: [.deepSeek: snapshot], thresholds: .defaults))
    }
}
