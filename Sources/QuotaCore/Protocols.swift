import Foundation

public protocol UsageProbe: Sendable {
    var providerID: ProviderID { get }
    func isAvailable() async -> Bool
    func fetch() async throws -> ProviderSnapshot
}

public protocol NetworkClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NetworkClient {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

public protocol CredentialProviding: Sendable {
    func credential(for providerID: ProviderID) throws -> String?
}

public struct CommandResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public protocol CommandRunning: Sendable {
    func locate(_ executable: String) -> String?
    func run(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval
    ) async throws -> CommandResult
}

public protocol InteractiveCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) async throws -> CommandResult
}
