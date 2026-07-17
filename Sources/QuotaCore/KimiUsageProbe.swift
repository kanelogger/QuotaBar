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
    private let requestTimeout: TimeInterval

    public init(
        credentials: any CredentialProviding,
        network: any NetworkClient = URLSession.shared,
        monthly: any KimiMonthlyUsageProviding = UnavailableKimiMonthlyProbe(),
        usageURL: URL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!,
        requestTimeout: TimeInterval = 20
    ) {
        self.credentials = credentials
        self.network = network
        self.monthly = monthly
        self.usageURL = usageURL
        self.requestTimeout = requestTimeout
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
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        let configuredRequest = request

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTaskGroup(
                of: (Data, URLResponse).self
            ) { group in
                group.addTask { try await network.data(for: configuredRequest) }
                group.addTask {
                    try await Task.sleep(for: .seconds(requestTimeout))
                    throw QuotaError.network("Kimi 请求超时")
                }
                guard let result = try await group.next() else {
                    throw QuotaError.network("Kimi 请求未返回")
                }
                group.cancelAll()
                return result
            }
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        try HTTPResponseValidator.validate(response)

        var metrics = try Self.parseUsage(data)
        let status: ProviderStatus = metrics.allSatisfy { $0.availability == .unavailable }
            ? .unavailable("未订阅 Kimi Code 或暂无可用额度")
            : .ready
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
            source: "Kimi Billing API",
            status: status
        )
    }

    public static func parseUsage(_ data: Data) throws -> [UsageMetric] {
        do {
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               root.isEmpty {
                return unsubscribedMetrics()
            }
            let response = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
            guard let coding = response.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
                return unsubscribedMetrics()
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
            throw QuotaError.invalidResponse("Kimi contract \(contractShape(data))")
        }
    }

    private static func unsubscribedMetrics() -> [UsageMetric] {
        [
            .unavailable(
                id: "weekly",
                name: "Weekly",
                window: .weekly,
                message: "未订阅 Kimi Code 或暂无额度"
            ),
            .unavailable(
                id: "five-hour",
                name: "5 hours",
                window: .fiveHour,
                message: "未订阅 Kimi Code 或暂无额度"
            ),
        ]
    }

    static func contractShape(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return "non-object"
        }

        var sections = ["root{\(fieldTypes(root))}"]
        if let usages = root["usages"] as? [Any] {
            sections.append("usages:\(usages.isEmpty ? "empty" : "array")")
            if let usage = usages.first as? [String: Any] {
                sections.append("usage{\(fieldTypes(usage))}")
                if let detail = usage["detail"] as? [String: Any] {
                    sections.append("detail{\(fieldTypes(detail))}")
                }
                if let limits = usage["limits"] as? [Any],
                   let limit = limits.first as? [String: Any] {
                    sections.append("limit{\(fieldTypes(limit))}")
                    if let window = limit["window"] as? [String: Any] {
                        sections.append("window{\(fieldTypes(window))}")
                    }
                    if let detail = limit["detail"] as? [String: Any] {
                        sections.append("limitDetail{\(fieldTypes(detail))}")
                    }
                }
            }
        }
        return sections.joined(separator: " ")
    }

    private static func fieldTypes(_ object: [String: Any]) -> String {
        object.keys
            .filter { key in
                !key.isEmpty && key.count <= 32
                    && key.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
                            .contains($0)
                    }
            }
            .sorted()
            .prefix(16)
            .map { "\($0):\(jsonType(object[$0]))" }
            .joined(separator: ",")
    }

    private static func jsonType(_ value: Any?) -> String {
        switch value {
        case is String: "string"
        case is NSNumber: "number"
        case is [Any]: "array"
        case is [String: Any]: "object"
        case is NSNull: "null"
        case nil: "missing"
        default: "other"
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
