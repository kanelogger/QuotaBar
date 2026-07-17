import Darwin
import Foundation

public struct SystemInteractiveCommandRunner: InteractiveCommandRunning, Sendable {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try await Task.detached {
            try Self.runSynchronously(
                executable: executable,
                arguments: arguments,
                input: input,
                timeout: timeout
            )
        }.value
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) throws -> CommandResult {
        guard let path = SystemCommandRunner().locate(executable) else {
            throw QuotaError.cliNotFound(executable)
        }

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var terminalSize = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &terminalSize) == 0 else {
            throw QuotaError.executionFailed("无法创建终端会话")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primary = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["CLICOLOR"] = "0"
        process.environment = environment

        var launched = false
        defer {
            try? primary.close()
            try? secondary.close()
            if launched, process.isRunning {
                terminateAndReap(process)
            }
        }

        do {
            try process.run()
            launched = true
        } catch {
            throw QuotaError.executionFailed(error.localizedDescription)
        }

        usleep(400_000)
        try primary.write(contentsOf: Data((input + "\r").utf8))

        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var lastDataAt = Date()
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while Date() < deadline {
            let count = Darwin.read(primaryFD, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                lastDataAt = Date()
            } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EIO {
                throw QuotaError.executionFailed(String(cString: strerror(errno)))
            }

            if !process.isRunning { break }
            if Date().timeIntervalSince(lastDataAt) >= 2.5,
               Self.containsTerminalResult(output) {
                break
            }
            usleep(50_000)
        }

        guard !output.isEmpty, let text = String(data: output, encoding: .utf8) else {
            throw QuotaError.executionFailed("Codex TTY 超时或没有输出")
        }
        return CommandResult(
            output: text,
            exitCode: process.isRunning ? -1 : process.terminationStatus
        )
    }

    private static func containsTerminalResult(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("weekly")
            || text.contains("not logged in")
            || text.contains("please log in")
    }
}
