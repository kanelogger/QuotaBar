import Foundation

public struct ProviderUpdate: Equatable, Sendable {
    public let snapshot: ProviderSnapshot?
    public let error: QuotaError?

    public init(snapshot: ProviderSnapshot?, error: QuotaError?) {
        self.snapshot = snapshot
        self.error = error
    }
}

public actor QuotaCoordinator {
    private let probes: [any UsageProbe]
    private let probeTimeout: TimeInterval
    private var lastSuccessful: [ProviderID: ProviderSnapshot] = [:]
    private var inFlight: [ProviderID: Task<ProviderSnapshot, Error>] = [:]

    public init(probes: [any UsageProbe], probeTimeout: TimeInterval = 45) {
        self.probes = probes
        self.probeTimeout = probeTimeout
    }

    public func refreshAll(
        onUpdate: (@Sendable (ProviderID, ProviderUpdate) async -> Void)? = nil
    ) async -> [ProviderID: ProviderUpdate] {
        var updates: [ProviderID: ProviderUpdate] = [:]
        let timeout = probeTimeout

        await withTaskGroup(of: (ProviderID, ProbeOutcome).self) { group in
            for probe in probes {
                let task = inFlight[probe.providerID] ?? Task.detached {
                    try await probe.fetch()
                }
                inFlight[probe.providerID] = task
                group.addTask {
                    (
                        probe.providerID,
                        await Self.wait(for: task, timeout: timeout)
                    )
                }
            }

            for await (providerID, outcome) in group {
                let result: Result<ProviderSnapshot, QuotaError>
                switch outcome {
                case .completed(let operationResult):
                    inFlight[providerID] = nil
                    result = operationResult.mapError(QuotaError.map)
                case .timedOut:
                    result = .failure(.executionFailed("\(providerID.displayName) 查询超时"))
                }
                switch result {
                case .success(let snapshot):
                    lastSuccessful[providerID] = snapshot
                    let update = ProviderUpdate(snapshot: snapshot, error: nil)
                    updates[providerID] = update
                    await onUpdate?(providerID, update)
                case .failure(let error):
                    let update = ProviderUpdate(
                        snapshot: lastSuccessful[providerID]?.markedStale(),
                        error: error
                    )
                    updates[providerID] = update
                    await onUpdate?(providerID, update)
                }
            }
        }

        return updates
    }

    private static func wait(
        for task: Task<ProviderSnapshot, Error>,
        timeout: TimeInterval
    ) async -> ProbeOutcome {
        await withCheckedContinuation { continuation in
            let gate = ProbeRaceGate(continuation: continuation)
            Task.detached {
                gate.finish(.completed(await task.result))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if gate.finish(.timedOut) {
                    task.cancel()
                }
            }
        }
    }
}

private enum ProbeOutcome: Sendable {
    case completed(Result<ProviderSnapshot, Error>)
    case timedOut
}

private final class ProbeRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeOutcome, Never>?

    init(continuation: CheckedContinuation<ProbeOutcome, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ outcome: ProbeOutcome) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<ProbeOutcome, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: outcome)
        return pending != nil
    }
}
