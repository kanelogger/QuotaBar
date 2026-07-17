import Foundation
import XCTest
@testable import QuotaCore

final class ProbeBehaviorTests: XCTestCase {
    func testSystemCommandRunnerTimeoutReturnsPromptly() async {
        let startedAt = Date()
        do {
            _ = try await SystemCommandRunner().run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                input: nil,
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(Date().timeIntervalSince(startedAt) < 1.5)
        }
    }

    func testOpenCodeMissingCLIHasSpecificError() async {
        let probe = OpenCodeProbe(runner: StubCommandRunner(executable: nil, results: []))

        do {
            _ = try await probe.fetch()
            XCTFail("Expected cliNotFound")
        } catch {
            XCTAssertEqual(error as? QuotaError, .cliNotFound("opencode"))
        }
    }

    func testOpenCodeEmptyDatabaseProducesZeroUsageWithoutInventingMonthlyReset() async throws {
        let runner = StubCommandRunner(
            executable: "/usr/local/bin/opencode",
            results: [CommandResult(
                output: #"[{"five_hour_cost":0,"weekly_cost":0,"five_hour_oldest_ms":null,"anchor_ms":null}]"#,
                exitCode: 0
            )]
        )
        let now = Date(timeIntervalSince1970: 1_784_278_400)
        let snapshot = try await OpenCodeProbe(runner: runner, now: { now }).fetch()

        XCTAssertEqual(snapshot.metrics.count, 3)
        XCTAssertEqual(snapshot.metrics.first(where: { $0.window == .monthly })?.used, 0)
        XCTAssertNil(snapshot.metrics.first(where: { $0.window == .monthly })?.resetsAt)
        XCTAssertEqual(runner.runCount, 1)
    }

    func testOpenCodeFiveHourResetUsesOldestIncludedMessage() async throws {
        let now = Date(timeIntervalSince1970: 1_784_278_400)
        let oldest = Int64(now.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000)
        let runner = StubCommandRunner(
            executable: "/usr/local/bin/opencode",
            results: [CommandResult(
                output: #"[{"five_hour_cost":1,"weekly_cost":1,"five_hour_oldest_ms":\#(oldest),"anchor_ms":null}]"#,
                exitCode: 0
            )]
        )

        let snapshot = try await OpenCodeProbe(runner: runner, now: { now }).fetch()

        XCTAssertEqual(
            snapshot.metrics.first(where: { $0.window == .fiveHour })?.resetsAt,
            now.addingTimeInterval(4 * 3_600)
        )
    }

    func testKimiMapsAuthenticationFailure() async {
        let response = HTTPURLResponse(
            url: URL(string: "https://www.kimi.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        let probe = KimiUsageProbe(
            credentials: StaticCredentials(values: [.kimi: "redacted"]),
            network: StubNetwork(data: Data(), response: response)
        )

        do {
            _ = try await probe.fetch()
            XCTFail("Expected authenticationExpired")
        } catch {
            XCTAssertEqual(error as? QuotaError, .authenticationExpired)
        }
    }

    func testKimiNetworkTimeoutReturnsPromptly() async {
        let probe = KimiUsageProbe(
            credentials: StaticCredentials(values: [.kimi: "redacted"]),
            network: HangingNetwork(),
            requestTimeout: 0.1
        )
        let startedAt = Date()

        do {
            _ = try await probe.fetch()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? QuotaError, .network("Kimi 请求超时"))
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        }
    }

    func testKimiFetchAddsMonthlyFallbackToBillingMetrics() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://www.kimi.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"20","resetTime":"2026-07-20T00:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","remaining":"40","resetTime":"2026-07-17T15:00:00Z"}}]}]}"#.utf8)
        let network = StubNetwork(data: body, response: response)
        let probe = KimiUsageProbe(
            credentials: StaticCredentials(values: [.kimi: "redacted"]),
            network: network
        )

        let snapshot = try await probe.fetch()

        XCTAssertEqual(snapshot.metrics.count, 3)
        XCTAssertEqual(snapshot.metrics.first(where: { $0.window == .monthly })?.availability, .unavailable)
        let request = await network.lastRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "connect-protocol-version"), "1")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/") == true)
        XCTAssertEqual(request?.httpMethod, "POST")
    }

    func testKimiRejectsResponseWithoutExactFiveHourWindow() {
        let body = Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"20"},"limits":[{"window":{"duration":60,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"50","remaining":"40"}}]}]}"#.utf8)

        XCTAssertThrowsError(try KimiUsageProbe.parseUsage(body))
    }

    func testKimiWithoutCodingSubscriptionReturnsUnavailableMetrics() throws {
        for body in [Data(#"{"usages":[]}"#.utf8), Data("{}".utf8)] {
            let metrics = try KimiUsageProbe.parseUsage(body)

            XCTAssertEqual(metrics.map(\.window), [.weekly, .fiveHour])
            XCTAssertTrue(metrics.allSatisfy { $0.availability == .unavailable })
        }
    }

    func testOpenCodeFetchesAnchoredMonthlyCost() async throws {
        let now = Date(timeIntervalSince1970: 1_784_278_400)
        let anchor = Int64(now.addingTimeInterval(-40 * 86_400).timeIntervalSince1970 * 1_000)
        let runner = StubCommandRunner(
            executable: "/usr/local/bin/opencode",
            results: [
                CommandResult(
                    output: #"[{"five_hour_cost":2,"weekly_cost":7,"five_hour_oldest_ms":null,"anchor_ms":\#(anchor)}]"#,
                    exitCode: 0
                ),
                CommandResult(output: #"[{"monthly_cost":11.5}]"#, exitCode: 0),
            ]
        )

        let snapshot = try await OpenCodeProbe(runner: runner, now: { now }).fetch()

        XCTAssertEqual(snapshot.metrics.first(where: { $0.window == .monthly })?.used, 11.5)
        XCTAssertNotNil(snapshot.metrics.first(where: { $0.window == .monthly })?.resetsAt)
        XCTAssertEqual(runner.runCount, 2)
    }

    func testOpenCodeMapsNonzeroDatabaseExit() async {
        let runner = StubCommandRunner(
            executable: "/usr/local/bin/opencode",
            results: [CommandResult(output: "database unavailable", exitCode: 2)]
        )

        do {
            _ = try await OpenCodeProbe(runner: runner).fetch()
            XCTFail("Expected executionFailed")
        } catch {
            XCTAssertEqual(error as? QuotaError, .executionFailed("opencode db 退出码 2"))
        }
    }

    func testCodexFallsBackToTTYWhenRPCFails() async throws {
        let interactive = StubInteractiveRunner(result: CommandResult(
            output: "Weekly limit\n42% left\nresets in 2d",
            exitCode: 0
        ))
        let client = CodexCLIClient(
            runner: StubCommandRunner(executable: "/usr/local/bin/codex", results: []),
            interactiveRunner: interactive,
            rpcFetcher: { throw QuotaError.executionFailed("RPC unavailable") }
        )

        let result = try await client.fetchWeekly()

        XCTAssertEqual(result.source, "codex /status")
        XCTAssertEqual(result.metric.percentRemaining, 42)
        XCTAssertEqual(result.metric.message, "resets in 2d")
    }

    func testCodexRPCTransportTimeoutReturnsPromptly() async throws {
        let transport = try ProcessRPCTransport(
            executablePath: "/bin/sh",
            arguments: ["-c", "read value"]
        )
        defer { transport.close() }
        let startedAt = Date()

        do {
            _ = try await transport.receive(timeout: 0.1)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? QuotaError, .executionFailed("Codex RPC 超时"))
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        }
    }

    func testDeepSeekPreservesBalancesButMarksUnavailableAccount() async throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/user/balance")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"8.00"}]}"#.utf8)
        let probe = DeepSeekProbe(
            credentials: StaticCredentials(values: [.deepSeek: "redacted"]),
            network: StubNetwork(data: body, response: response)
        )

        let snapshot = try await probe.fetch()

        XCTAssertEqual(snapshot.metrics.first?.remaining, 8)
        XCTAssertEqual(snapshot.status, .unavailable("账户当前不可调用 API"))
        XCTAssertNil(QuotaSummary.make(snapshots: [.deepSeek: snapshot], thresholds: .defaults))
    }

    func testDeepSeekAcceptsZeroBalance() throws {
        let body = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"0.00"}]}"#.utf8)

        let balance = try DeepSeekProbe.parseBalance(body)

        XCTAssertEqual(balance.metrics.first?.balanceAmount, Decimal.zero)
        XCTAssertEqual(balance.metrics.first?.percentRemaining, nil)
    }

    func testDeepSeekMapsAuthenticationFailure() async {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.deepseek.com/user/balance")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        let probe = DeepSeekProbe(
            credentials: StaticCredentials(values: [.deepSeek: "redacted"]),
            network: StubNetwork(data: Data(), response: response)
        )

        do {
            _ = try await probe.fetch()
            XCTFail("Expected authenticationExpired")
        } catch {
            XCTAssertEqual(error as? QuotaError, .authenticationExpired)
        }
    }

    func testCodexMissingCLIHasSpecificError() async {
        let probe = CodexProbe(client: StubCodexClient(available: false))

        do {
            _ = try await probe.fetch()
            XCTFail("Expected cliNotFound")
        } catch {
            XCTAssertEqual(error as? QuotaError, .cliNotFound("codex"))
        }
    }
}

private struct StaticCredentials: CredentialProviding {
    let values: [ProviderID: String]

    func credential(for providerID: ProviderID) throws -> String? {
        values[providerID]
    }
}

private actor StubNetwork: NetworkClient {
    let data: Data
    let response: URLResponse
    private(set) var lastRequest: URLRequest?

    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return (data, response)
    }
}

private struct HangingNetwork: NetworkClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw QuotaError.unknown("unreachable")
    }
}

private struct StubInteractiveRunner: InteractiveCommandRunning {
    let result: CommandResult

    func run(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        result
    }
}

private struct StubCodexClient: CodexRateLimitProviding {
    let available: Bool

    func isAvailable() -> Bool { available }

    func fetchWeekly() async throws -> CodexWeeklyResult {
        throw QuotaError.notLoggedIn
    }
}

private final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    let executable: String?
    private var results: [CommandResult]
    private let lock = NSLock()
    private var count = 0

    init(executable: String?, results: [CommandResult]) {
        self.executable = executable
        self.results = results
    }

    var runCount: Int {
        lock.withLock { count }
    }

    func locate(_ executable: String) -> String? {
        self.executable
    }

    func run(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try lock.withLock {
            count += 1
            guard !results.isEmpty else {
                throw QuotaError.executionFailed("Missing stub result")
            }
            return results.removeFirst()
        }
    }
}
