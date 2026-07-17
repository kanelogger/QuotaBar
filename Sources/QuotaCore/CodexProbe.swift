import Darwin
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
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw QuotaError.executionFailed("Codex RPC 超时")
            }
            let data = try await transport.receive(timeout: remaining)
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
    private let readLock = NSLock()
    private var isClosed = false
    private var readBuffer = Data()

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

    func receive(timeout: TimeInterval) async throws -> Data {
        try await Task.detached {
            try self.receiveSynchronously(timeout: timeout)
        }.value
    }

    private func receiveSynchronously(timeout: TimeInterval) throws -> Data {
        try readLock.withLock {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let newline = readBuffer.firstIndex(of: 0x0A) {
                    let line = Data(readBuffer[..<newline])
                    readBuffer.removeSubrange(readBuffer.startIndex...newline)
                    if !line.isEmpty { return line }
                    continue
                }

                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw QuotaError.executionFailed("Codex RPC 超时")
                }

                let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
                var descriptor = pollfd(
                    fd: output.fileHandleForReading.fileDescriptor,
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                )
                let ready = Darwin.poll(&descriptor, 1, milliseconds)
                if ready == 0 {
                    throw QuotaError.executionFailed("Codex RPC 超时")
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw QuotaError.executionFailed(String(cString: strerror(errno)))
                }

                var buffer = [UInt8](repeating: 0, count: 8_192)
                let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
                if count > 0 {
                    readBuffer.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    throw QuotaError.executionFailed("Codex 进程意外退出")
                }
                if errno == EINTR || errno == EAGAIN { continue }
                throw QuotaError.executionFailed(String(cString: strerror(errno)))
            }
        }
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
