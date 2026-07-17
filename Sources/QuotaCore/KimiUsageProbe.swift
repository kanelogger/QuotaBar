import Foundation

private struct KimiUsageResponse: Decodable {
    struct Detail: Decodable, KimiDetail {
        let limit: String
        let used: String?
        let remaining: String?
        let resetTime: String?
    }
    struct RateLimit: Decodable {
        struct Window: Decodable {
            let duration: Int
            let timeUnit: String
        }
        let window: Window
        let detail: Detail
    }
    struct Usage: Decodable {
        let scope: String
        let detail: Detail
        let limits: [RateLimit]?
    }
    let usages: [Usage]
}

public protocol KimiMonthlyUsageProviding: Sendable {
    func fetchMonthlyMetric(token: String) async throws -> UsageMetric
}

public struct UnavailableKimiMonthlyProbe: KimiMonthlyUsageProviding {
    public init() {}

    public func fetchMonthlyMetric(token: String) async throws -> UsageMetric {
        .unavailable(
            id: "monthly",
            name: "Monthly",
            window: .monthly,
            message: "暂不可查询，请在 Kimi 订阅页查看"
        )
    }
}

public struct KimiUsageProbe: UsageProbe {
    public let providerID: ProviderID = .kimi

    private let credentials: any CredentialProviding
    private let network: any NetworkClient
    private let monthly: any KimiMonthlyUsageProviding
    private let usageURL: URL

    public init(
        credentials: any CredentialProviding,
        network: any NetworkClient = URLSession.shared,
        monthly: any KimiMonthlyUsageProviding = UnavailableKimiMonthlyProbe(),
        usageURL: URL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
    ) {
        self.credentials = credentials
        self.network = network
        self.monthly = monthly
        self.usageURL = usageURL
    }

    public func isAvailable() async -> Bool {
        (try? credentials.credential(for: providerID))?.isEmpty == false
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let token = try credentials.credential(for: providerID), !token.isEmpty else {
            throw QuotaError.notConfigured
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        try HTTPResponseValidator.validate(response)

        var metrics = try Self.parseUsage(data)
        do {
            metrics.append(try await monthly.fetchMonthlyMetric(token: token))
        } catch {
            metrics.append(.unavailable(
                id: "monthly",
                name: "Monthly",
                window: .monthly,
                message: "月额度接口不可用"
            ))
        }

        return ProviderSnapshot(
            providerID: providerID,
            metrics: metrics,
            capturedAt: Date(),
            source: "Kimi Billing API"
        )
    }

    public static func parseUsage(_ data: Data) throws -> [UsageMetric] {
        do {
            let response = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
            guard let coding = response.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
                throw QuotaError.invalidResponse("缺少 FEATURE_CODING")
            }
            let weekly = try usageNumbers(coding.detail)
            var metrics: [UsageMetric] = [
                .quota(
                    id: "weekly",
                    name: "Weekly",
                    window: .weekly,
                    used: weekly.used,
                    total: weekly.total,
                    unit: "requests",
                    resetsAt: parseDate(coding.detail.resetTime)
                )
            ]

            guard let rate = coding.limits?.first(where: {
                $0.window.duration == 300 && $0.window.timeUnit == "TIME_UNIT_MINUTE"
            }) else {
                throw QuotaError.invalidResponse("缺少 Kimi 5 小时额度")
            }
            let numbers = try usageNumbers(rate.detail)
            metrics.append(.quota(
                id: "five-hour",
                name: "5 hours",
                window: .fiveHour,
                used: numbers.used,
                total: numbers.total,
                unit: "requests",
                resetsAt: parseDate(rate.detail.resetTime)
            ))
            return metrics
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse(error.localizedDescription)
        }
    }

    private static func usageNumbers<T>(_ detail: T) throws -> (used: Double, total: Double) where T: KimiDetail {
        guard let total = Double(detail.limit), total >= 0 else {
            throw QuotaError.invalidResponse("Kimi limit 无法解析")
        }
        if let rawUsed = detail.used, let used = Double(rawUsed) {
            return (max(0, used), total)
        }
        if let rawRemaining = detail.remaining, let remaining = Double(rawRemaining) {
            return (max(0, total - remaining), total)
        }
        throw QuotaError.invalidResponse("Kimi usage 缺少 used/remaining")
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

}

private protocol KimiDetail {
    var limit: String { get }
    var used: String? { get }
    var remaining: String? { get }
}
