import Foundation
import XCTest
@testable import QuotaCore

final class CoordinatorTests: XCTestCase {
    func testPartialFailurePreservesOtherProvidersAndStaleLastSuccess() async {
        let goodSnapshot = ProviderSnapshot(
            providerID: .codex,
            metrics: [.quota(id: "weekly", name: "Weekly", window: .weekly, used: 20, total: 100)],
            capturedAt: Date(),
            source: "test"
        )
        let good = StubProbe(providerID: .codex, outcomes: [.success(goodSnapshot), .failure(.network("offline"))])
        let bad = StubProbe(providerID: .deepSeek, outcomes: [.failure(.notConfigured)])
        let coordinator = QuotaCoordinator(probes: [good, bad])

        let first = await coordinator.refreshAll()
        XCTAssertNotNil(first[.codex]?.snapshot)
        XCTAssertEqual(first[.deepSeek]?.error, .notConfigured)

        let second = await coordinator.refreshAll()
        XCTAssertEqual(second[.codex]?.error, .network("offline"))
        XCTAssertEqual(second[.codex]?.snapshot?.isStale, true)
    }

    func testPublishesFastProviderBeforeSlowProviderCompletes() async {
        let recorder = UpdateRecorder()
        let fast = DelayedProbe(providerID: .codex, delay: .milliseconds(20))
        let slow = DelayedProbe(providerID: .kimi, delay: .milliseconds(300))
        let coordinator = QuotaCoordinator(probes: [slow, fast])

        let refresh = Task {
            await coordinator.refreshAll { providerID, _ in
                await recorder.append(providerID)
            }
        }
        try? await Task.sleep(for: .milliseconds(100))

        let partialValues = await recorder.values
        XCTAssertEqual(partialValues, [.codex])
        _ = await refresh.value
        let finalValues = await recorder.values
        XCTAssertEqual(finalValues, [.codex, .kimi])
    }
}

private actor UpdateRecorder {
    private(set) var values: [ProviderID] = []

    func append(_ providerID: ProviderID) {
        values.append(providerID)
    }
}

private struct DelayedProbe: UsageProbe {
    let providerID: ProviderID
    let delay: Duration

    func isAvailable() async -> Bool { true }

    func fetch() async throws -> ProviderSnapshot {
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

private final class StubProbe: UsageProbe, @unchecked Sendable {
    let providerID: ProviderID
    private var outcomes: [Result<ProviderSnapshot, QuotaError>]
    private let lock = NSLock()

    init(providerID: ProviderID, outcomes: [Result<ProviderSnapshot, QuotaError>]) {
        self.providerID = providerID
        self.outcomes = outcomes
    }

    func isAvailable() async -> Bool { true }

    func fetch() async throws -> ProviderSnapshot {
        try lock.withLock {
            try outcomes.removeFirst().get()
        }
    }
}
