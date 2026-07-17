import Foundation
import XCTest
@testable import QuotaBar
import QuotaCore

@MainActor
final class AppModelTests: XCTestCase {
    func testRefreshRequestedDuringActiveRefreshRunsAgain() async {
        let probe = CountingProbe(delay: .milliseconds(100))
        let model = makeModel(probes: [probe])

        let firstRefresh = Task { await model.refresh() }
        while !model.isRefreshing { await Task.yield() }
        await model.refresh()
        await firstRefresh.value

        XCTAssertEqual(probe.fetchCount, 2)
    }

    func testFastProviderAppearsBeforeSlowProviderFinishes() async {
        let fast = CountingProbe(providerID: .codex, delay: .milliseconds(20))
        let slow = CountingProbe(providerID: .kimi, delay: .milliseconds(300))
        let model = makeModel(probes: [slow, fast])

        let refresh = Task { await model.refresh() }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(model.updates[.codex]?.snapshot)
        XCTAssertNil(model.updates[.kimi])
        await refresh.value
        XCTAssertNotNil(model.updates[.kimi]?.snapshot)
    }

    func testKimiManualTokenTakesPriorityOverBrowserImport() throws {
        let credentials = MemoryCredentialStore()
        try credentials.set("manual-token", for: .kimi)
        let browserCalls = LockedCounter()
        let provider = KimiCredentialProvider(keychain: credentials) {
            browserCalls.increment()
            return "browser-token"
        }

        XCTAssertEqual(try provider.credential(for: .kimi), "manual-token")
        XCTAssertEqual(browserCalls.value, 0)
    }

    func testKimiUsesBrowserTokenWhenManualTokenIsMissing() throws {
        let provider = KimiCredentialProvider(keychain: MemoryCredentialStore()) {
            "browser-token"
        }

        XCTAssertEqual(try provider.credential(for: .kimi), "browser-token")
    }

    private func makeModel(probes: [any UsageProbe]) -> AppModel {
        let suiteName = "QuotaBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            settings: AppSettings(defaults: defaults),
            credentials: MemoryCredentialStore(),
            coordinator: QuotaCoordinator(probes: probes)
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class CountingProbe: UsageProbe, @unchecked Sendable {
    let providerID: ProviderID
    let delay: Duration
    private let lock = NSLock()
    private var count = 0

    init(providerID: ProviderID = .codex, delay: Duration) {
        self.providerID = providerID
        self.delay = delay
    }

    var fetchCount: Int { lock.withLock { count } }

    func isAvailable() async -> Bool { true }

    func fetch() async throws -> ProviderSnapshot {
        lock.withLock { count += 1 }
        try await Task.sleep(for: delay)
        return ProviderSnapshot(
            providerID: providerID,
            metrics: [.percentageQuota(
                id: "weekly",
                name: "Weekly",
                window: .weekly,
                percentRemaining: 50
            )],
            capturedAt: Date(),
            source: "test"
        )
    }
}

private final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderID: String] = [:]

    func credential(for providerID: ProviderID) throws -> String? {
        lock.withLock { values[providerID] }
    }

    func set(_ value: String, for providerID: ProviderID) throws {
        lock.withLock { values[providerID] = value }
    }

    func delete(for providerID: ProviderID) throws {
        lock.withLock { values[providerID] = nil }
    }
}
