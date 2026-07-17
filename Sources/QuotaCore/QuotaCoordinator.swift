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
    private var lastSuccessful: [ProviderID: ProviderSnapshot] = [:]

    public init(probes: [any UsageProbe]) {
        self.probes = probes
    }

    public func refreshAll(
        onUpdate: (@Sendable (ProviderID, ProviderUpdate) async -> Void)? = nil
    ) async -> [ProviderID: ProviderUpdate] {
        var updates: [ProviderID: ProviderUpdate] = [:]

        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, QuotaError>).self) { group in
            for probe in probes {
                group.addTask {
                    do {
                        return (probe.providerID, .success(try await probe.fetch()))
                    } catch {
                        return (probe.providerID, .failure(QuotaError.map(error)))
                    }
                }
            }

            for await (providerID, result) in group {
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
}
