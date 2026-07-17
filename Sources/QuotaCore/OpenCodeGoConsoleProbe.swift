import Foundation

public struct OpenCodeGoConsoleProbe: UsageProbe {
    public let providerID: ProviderID = .openCodeGo

    public init() {}

    public func isAvailable() async -> Bool { true }

    public func fetch() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            metrics: [.unavailable(
                id: "official-console",
                name: "Official console",
                window: .monthly,
                message: "Usage is available in the official console."
            )],
            capturedAt: Date(),
            source: "opencode-console"
        )
    }
}
