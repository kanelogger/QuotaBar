import Foundation

public struct SystemCommandRunner: CommandRunning, Sendable {
    public init() {}

    public func locate(_ executable: String) -> String? {
        if executable.contains("/"), FileManager.default.isExecutableFile(atPath: executable) {
            return executable
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        guard let path = locate(executable) else {
            throw QuotaError.cliNotFound(executable)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let termination = ProcessTerminationSignal()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        process.terminationHandler = { _ in termination.complete() }

        do {
            try process.run()
        } catch {
            throw QuotaError.executionFailed(error.localizedDescription)
        }

        let stdoutTask = Task.detached { Self.readAll(from: stdout.fileHandleForReading) }
        let stderrTask = Task.detached { Self.readAll(from: stderr.fileHandleForReading) }

        if let input, let data = input.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        do {
            try await Self.waitForTermination(termination, timeout: timeout)
        } catch {
            terminateAndReap(process)
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            stdoutTask.cancel()
            stderrTask.cancel()
            throw error
        }

        let outputData = await stdoutTask.value
        let errorData = await stderrTask.value
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        return CommandResult(
            output: output.isEmpty ? errorOutput : output,
            exitCode: process.terminationStatus
        )
    }

    private static func waitForTermination(
        _ signal: ProcessTerminationSignal,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await signal.wait() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw QuotaError.executionFailed("命令执行超时")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func readAll(from handle: FileHandle) -> Data {
        var data = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }
}

private final class ProcessTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if completed || cancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                cancelled = true
                defer { continuation = nil }
                return continuation
            }
            pending?.resume()
        }
    }

    func complete() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            completed = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
