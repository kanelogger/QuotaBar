import Foundation

enum HTTPResponseValidator {
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.invalidResponse("无效的 HTTP 响应")
        }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw QuotaError.authenticationExpired
        case 429: throw QuotaError.rateLimited
        default: throw QuotaError.network("HTTP \(http.statusCode)")
        }
    }
}
