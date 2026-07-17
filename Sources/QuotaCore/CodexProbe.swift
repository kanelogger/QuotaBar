import Foundation

public protocol CodexRateLimitProviding: Sendable {
    func isAvailable() -> Bool
    func fetchWeekly() async throws -> CodexWeeklyResult
}

public struct CodexWeeklyResult: Sendable {
    public let metric: UsageMetric
    public let source: String

    public init(metric: UsageMetric, source: String) {
        self.metric = metric
        self.source = source
    }
}

public struct CodexProbe: UsageProbe {
    public let providerID: ProviderID = .codex
    private let client: any CodexRateLimitProviding

    public init(client: any CodexRateLimitProviding = CodexCLIClient()) {
        self.client = client
    }

    public func isAvailable() async -> Bool {
        client.isAvailable()
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard client.isAvailable() else {
            throw QuotaError.cliNotFound("codex")
        }
        let result = try await client.fetchWeekly()
        return ProviderSnapshot(
            providerID: providerID,
            metrics: [result.metric],
            capturedAt: Date(),
            source: result.source
        )
    }

    public static func parseRPCResponse(_ data: Data) throws -> UsageMetric {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidResponse("Codex RPC 不是 JSON")
        }
        let result = root["result"] as? [String: Any]
        let rateLimits = (result?["rateLimits"] as? [String: Any])
            ?? (root["rateLimits"] as? [String: Any])
        let secondary = rateLimits?["secondary"] as? [String: Any]
        let primary = rateLimits?["primary"] as? [String: Any]
        let weekly = secondary ?? primary.flatMap { window in
            guard let minutes = number(window["windowDurationMins"]), minutes >= 7 * 24 * 60 else {
                return nil
            }
            return window
        }
        guard let weekly,
              let used = number(weekly["usedPercent"]) else {
            throw QuotaError.invalidResponse("缺少 Codex weekly rate limit")
        }
        let resetSeconds = number(weekly["resetsAt"])
        let resetDate = resetSeconds.map(Date.init(timeIntervalSince1970:))
        return .percentageQuota(
            id: "weekly",
            name: "Weekly",
            window: .weekly,
            percentRemaining: max(0, 100 - used),
            resetsAt: resetDate
        )
    }

    public static func parseTTY(_ text: String) throws -> UsageMetric {
        let clean = text.replacingOccurrences(
            of: #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#,
            with: "",
            options: .regularExpression
        )
        if clean.lowercased().contains("not logged in") || clean.lowercased().contains("please log in") {
            throw QuotaError.notLoggedIn
        }
        let lines = clean.components(separatedBy: .newlines)
        guard let weeklyIndex = lines.firstIndex(where: { $0.lowercased().contains("weekly") }) else {
            throw QuotaError.invalidResponse("TTY 输出缺少 Weekly limit")
        }
        let relevant = lines[weeklyIndex...].prefix(12).joined(separator: "\n")
        guard let range = relevant.range(of: #"([0-9]{1,3})%\s+left"#, options: [.regularExpression, .caseInsensitive]),
              let percent = Double(relevant[range].prefix(while: { $0.isNumber })) else {
            throw QuotaError.invalidResponse("TTY 输出缺少剩余百分比")
        }
        return .percentageQuota(
            id: "weekly",
            name: "Weekly",
            window: .weekly,
            percentRemaining: percent,
            message: lines[weeklyIndex...].first(where: { $0.lowercased().contains("reset") })
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

public struct CodexCLIClient: CodexRateLimitProviding {
    private let runner: any CommandRunning
    private let interactiveRunner: any InteractiveCommandRunning
    private let timeout: TimeInterval
    private let rpcFetcher: (@Sendable () async throws -> UsageMetric)?

    public init(
        runner: any CommandRunning = SystemCommandRunner(),
        interactiveRunner: any InteractiveCommandRunning = SystemInteractiveCommandRunner(),
        timeout: TimeInterval = 15
    ) {
        self.runner = runner
        self.interactiveRunner = interactiveRunner
        self.timeout = timeout
        self.rpcFetcher = nil
    }

    init(
        runner: any CommandRunning,
        interactiveRunner: any InteractiveCommandRunning,
        timeout: TimeInterval = 15,
        rpcFetcher: @escaping @Sendable () async throws -> UsageMetric
    ) {
        self.runner = runner
        self.interactiveRunner = interactiveRunner
        self.timeout = timeout
        self.rpcFetcher = rpcFetcher
    }

    public func isAvailable() -> Bool {
        runner.locate("codex") != nil
    }

    public func fetchWeekly() async throws -> CodexWeeklyResult {
        do {
            let metric = if let rpcFetcher {
                try await rpcFetcher()
            } else {
                try await fetchViaRPC()
            }
            return CodexWeeklyResult(metric: metric, source: "codex app-server")
        } catch {
            return CodexWeeklyResult(metric: try await fetchViaTTY(), source: "codex /status")
        }
    }

    private func fetchViaRPC() async throws -> UsageMetric {
        guard let executable = runner.locate("codex") else {
            throw QuotaError.cliNotFound("codex")
        }
        let transport = try ProcessRPCTransport(
            executablePath: executable,
            arguments: ["-s", "read-only", "-a", "untrusted", "app-server"]
        )
        defer { transport.close() }

        try transport.send([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "quotabar", "version": "1.0.0"]],
        ])
        _ = try await response(id: 1, transport: transport)
        try transport.send(["method": "initialized", "params": [:]])
        try transport.send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
        return try CodexProbe.parseRPCResponse(try await response(id: 2, transport: transport))
    }

    private func response(id: Int, transport: ProcessRPCTransport) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                while true {
                    let data = try await transport.receive()
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let responseID = object["id"] as? Int,
                       responseID == id {
                        if let error = object["error"] as? [String: Any] {
                            throw QuotaError.executionFailed(error["message"] as? String ?? "RPC error")
                        }
                        return data
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                transport.close()
                throw QuotaError.executionFailed("Codex RPC 超时")
            }
            guard let first = try await group.next() else {
                throw QuotaError.executionFailed("Codex RPC 已关闭")
            }
            group.cancelAll()
            return first
        }
    }

    private func fetchViaTTY() async throws -> UsageMetric {
        let result = try await interactiveRunner.run(
            executable: "codex",
            arguments: ["-s", "read-only", "-a", "untrusted"],
            input: "/status",
            timeout: 20
        )
        return try CodexProbe.parseTTY(result.output)
    }
}

final class ProcessRPCTransport: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let closeLock = NSLock()
    private var isClosed = false

    init(executablePath: String, arguments: [String]) throws {
        process = Process()
        input = Pipe()
        output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw QuotaError.executionFailed(error.localizedDescription)
        }
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }

    func receive() async throws -> Data {
        for try await line in output.fileHandleForReading.bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            return data
        }
        throw QuotaError.executionFailed("Codex 进程意外退出")
    }

    func close() {
        let shouldClose = closeLock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        terminateAndReap(process)
    }
}
