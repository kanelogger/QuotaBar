import Foundation

public struct OpenCodeProbe: UsageProbe {
    public let providerID: ProviderID = .openCodeGo

    public static let fiveHourLimit = 12.0
    public static let weeklyLimit = 30.0
    public static let monthlyLimit = 60.0

    private let runner: any CommandRunning
    private let now: @Sendable () -> Date

    public init(
        runner: any CommandRunning = SystemCommandRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.now = now
    }

    public func isAvailable() async -> Bool {
        runner.locate("opencode") != nil
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let executable = runner.locate("opencode") else {
            throw QuotaError.cliNotFound("opencode")
        }

        let current = now()
        let fiveHourStart = current.addingTimeInterval(-5 * 3_600)
        let weekStart = Self.startOfWeekUTC(from: current)
        let weekEnd = Self.endOfWeekUTC(from: current)
        let primary = try Self.parsePrimary(
            try await query(
                executable: executable,
                sql: Self.primarySQL(
                    fiveHourStartMilliseconds: Self.milliseconds(fiveHourStart),
                    weekStartMilliseconds: Self.milliseconds(weekStart)
                )
            )
        )

        let monthCost: Double
        let monthEnd: Date?
        if let anchorMilliseconds = primary.anchorMilliseconds {
            let anchor = Date(timeIntervalSince1970: Double(anchorMilliseconds) / 1_000)
            let bounds = Self.anchoredMonthBounds(now: current, anchor: anchor)
            monthEnd = bounds.end
            monthCost = try Self.parseMonthly(
                try await query(
                    executable: executable,
                    sql: Self.monthlySQL(
                        startMilliseconds: Self.milliseconds(bounds.start),
                        endMilliseconds: Self.milliseconds(bounds.end)
                    )
                )
            )
        } else {
            monthCost = 0
            monthEnd = nil
        }

        let metrics: [UsageMetric] = [
            .quota(
                id: "five-hour",
                name: "5 hours",
                window: .fiveHour,
                used: primary.fiveHourCost,
                total: Self.fiveHourLimit,
                unit: "USD",
                resetsAt: Self.fiveHourReset(oldestMilliseconds: primary.fiveHourOldestMilliseconds, now: current)
            ),
            .quota(
                id: "weekly",
                name: "Weekly",
                window: .weekly,
                used: primary.weeklyCost,
                total: Self.weeklyLimit,
                unit: "USD",
                resetsAt: weekEnd
            ),
            .quota(
                id: "monthly",
                name: "Monthly",
                window: .monthly,
                used: monthCost,
                total: Self.monthlyLimit,
                unit: "USD",
                resetsAt: monthEnd
            ),
        ]

        return ProviderSnapshot(
            providerID: providerID,
            metrics: metrics,
            capturedAt: current,
            source: "opencode db"
        )
    }

    private func query(executable: String, sql: String) async throws -> Data {
        let result = try await runner.run(
            executable: executable,
            arguments: ["db", sql, "--format", "json"],
            input: nil,
            timeout: 15
        )
        guard result.exitCode == 0 else {
            throw QuotaError.executionFailed("opencode db 退出码 \(result.exitCode)")
        }
        guard let data = result.output.data(using: .utf8) else {
            throw QuotaError.invalidResponse("无法读取 opencode 输出")
        }
        return data
    }

    private static let filteredRows = """
    SELECT
      CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS t,
      CAST(json_extract(data, '$.cost') AS REAL) AS cost
    FROM message
    WHERE json_valid(data)
      AND json_extract(data, '$.providerID') = 'opencode-go'
      AND json_extract(data, '$.role') = 'assistant'
      AND json_type(data, '$.cost') IN ('integer', 'real')
    """

    public static func primarySQL(
        fiveHourStartMilliseconds: Int64,
        weekStartMilliseconds: Int64
    ) -> String {
        """
        SELECT
          COALESCE(SUM(CASE WHEN t >= \(fiveHourStartMilliseconds) THEN cost ELSE 0 END), 0) AS five_hour_cost,
          COALESCE(SUM(CASE WHEN t >= \(weekStartMilliseconds) THEN cost ELSE 0 END), 0) AS weekly_cost,
          MIN(CASE WHEN t >= \(fiveHourStartMilliseconds) THEN t ELSE NULL END) AS five_hour_oldest_ms,
          MIN(t) AS anchor_ms
        FROM (\(filteredRows))
        """
    }

    public static func monthlySQL(startMilliseconds: Int64, endMilliseconds: Int64) -> String {
        """
        SELECT COALESCE(SUM(cost), 0) AS monthly_cost
        FROM (\(filteredRows))
        WHERE t >= \(startMilliseconds) AND t < \(endMilliseconds)
        """
    }

    public static func anchoredMonthBounds(now: Date, anchor: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let anchorParts = calendar.dateComponents([.day, .hour, .minute, .second], from: anchor)
        let nowParts = calendar.dateComponents([.year, .month], from: now)
        let currentMonth = calendar.date(from: DateComponents(
            year: nowParts.year,
            month: nowParts.month,
            day: 1
        )) ?? now

        var startMonth = currentMonth
        var start = anchoredDate(in: startMonth, anchorParts: anchorParts, calendar: calendar)
        if start > now,
           let previousMonth = calendar.date(byAdding: .month, value: -1, to: startMonth) {
            startMonth = previousMonth
            start = anchoredDate(in: startMonth, anchorParts: anchorParts, calendar: calendar)
        }
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: startMonth) ?? startMonth
        let end = anchoredDate(in: nextMonth, anchorParts: anchorParts, calendar: calendar)
        return (start, end)
    }

    private static func anchoredDate(
        in month: Date,
        anchorParts: DateComponents,
        calendar: Calendar
    ) -> Date {
        let monthParts = calendar.dateComponents([.year, .month], from: month)
        let dayRange = calendar.range(of: .day, in: .month, for: month) ?? 1..<29
        return calendar.date(from: DateComponents(
            year: monthParts.year,
            month: monthParts.month,
            day: min(anchorParts.day ?? 1, dayRange.count),
            hour: anchorParts.hour,
            minute: anchorParts.minute,
            second: anchorParts.second
        )) ?? month
    }

    public static func startOfWeekUTC(from date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let weekday = calendar.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: date) ?? date
        return calendar.startOfDay(for: monday)
    }

    public static func endOfWeekUTC(from date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(byAdding: .day, value: 7, to: startOfWeekUTC(from: date)) ?? date
    }

    static func parsePrimary(_ data: Data) throws -> PrimaryUsage {
        struct Row: Decodable {
            let five_hour_cost: Double
            let weekly_cost: Double
            let five_hour_oldest_ms: Int64?
            let anchor_ms: Int64?
        }
        do {
            guard let row = try JSONDecoder().decode([Row].self, from: data).first else {
                throw QuotaError.invalidResponse("OpenCode 查询没有返回数据")
            }
            return PrimaryUsage(
                fiveHourCost: row.five_hour_cost,
                weeklyCost: row.weekly_cost,
                fiveHourOldestMilliseconds: row.five_hour_oldest_ms,
                anchorMilliseconds: row.anchor_ms
            )
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse(error.localizedDescription)
        }
    }

    static func parseMonthly(_ data: Data) throws -> Double {
        struct Row: Decodable { let monthly_cost: Double }
        do {
            return try JSONDecoder().decode([Row].self, from: data).first?.monthly_cost ?? 0
        } catch {
            throw QuotaError.invalidResponse(error.localizedDescription)
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func fiveHourReset(oldestMilliseconds: Int64?, now: Date) -> Date {
        guard let oldestMilliseconds else { return now.addingTimeInterval(5 * 3_600) }
        return Date(timeIntervalSince1970: Double(oldestMilliseconds) / 1_000)
            .addingTimeInterval(5 * 3_600)
    }
}

struct PrimaryUsage: Equatable, Sendable {
    let fiveHourCost: Double
    let weeklyCost: Double
    let fiveHourOldestMilliseconds: Int64?
    let anchorMilliseconds: Int64?
}
