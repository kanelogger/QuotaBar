import Foundation

public struct DeepSeekProbe: UsageProbe {
    public let providerID: ProviderID = .deepSeek

    private let credentials: any CredentialProviding
    private let network: any NetworkClient
    private let baseURL: URL

    public init(
        credentials: any CredentialProviding,
        network: any NetworkClient = URLSession.shared,
        baseURL: URL = URL(string: "https://api.deepseek.com")!
    ) {
        self.credentials = credentials
        self.network = network
        self.baseURL = baseURL
    }

    public func isAvailable() async -> Bool {
        (try? credentials.credential(for: providerID))?.isEmpty == false
    }

    public func fetch() async throws -> ProviderSnapshot {
        guard let token = try credentials.credential(for: providerID), !token.isEmpty else {
            throw QuotaError.notConfigured
        }
        let url = baseURL.appending(path: "user/balance")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.data(for: request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
        try HTTPResponseValidator.validate(response)
        let balance = try Self.parseBalance(data)
        return ProviderSnapshot(
            providerID: providerID,
            metrics: balance.metrics,
            capturedAt: Date(),
            source: "DeepSeek API",
            status: balance.isAvailable ? .ready : .unavailable("账户当前不可调用 API")
        )
    }

    public static func parseBalance(_ data: Data) throws -> (metrics: [UsageMetric], isAvailable: Bool) {
        struct Response: Decodable {
            struct Balance: Decodable {
                let currency: String
                let totalBalance: String

                enum CodingKeys: String, CodingKey {
                    case currency
                    case totalBalance = "total_balance"
                }
            }
            let isAvailable: Bool
            let balanceInfos: [Balance]

            enum CodingKeys: String, CodingKey {
                case isAvailable = "is_available"
                case balanceInfos = "balance_infos"
            }
        }

        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard !response.balanceInfos.isEmpty else {
                throw QuotaError.invalidResponse("余额列表为空")
            }
            let metrics = try response.balanceInfos.map { item in
                guard let amount = Decimal(
                    string: item.totalBalance,
                    locale: Locale(identifier: "en_US_POSIX")
                ), amount >= .zero else {
                    throw QuotaError.invalidResponse("无法解析 \(item.currency) 余额")
                }
                return UsageMetric.balance(
                    currency: item.currency,
                    decimalAmount: amount,
                    message: response.isAvailable ? nil : "账户当前不可调用 API"
                )
            }
            return (metrics, response.isAvailable)
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse(error.localizedDescription)
        }
    }

}
