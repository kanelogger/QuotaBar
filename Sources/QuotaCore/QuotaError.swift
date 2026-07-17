import Foundation

public enum QuotaError: Error, Equatable, Sendable {
    case cliNotFound(String)
    case notLoggedIn
    case notConfigured
    case authenticationExpired
    case rateLimited
    case network(String)
    case invalidResponse(String)
    case executionFailed(String)
    case permissionDenied(String)
    case unknown(String)
}

extension QuotaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let name): "未找到 \(name) 命令行工具"
        case .notLoggedIn: "尚未登录"
        case .notConfigured: "尚未配置凭据"
        case .authenticationExpired: "登录凭据已过期"
        case .rateLimited: "查询过于频繁，请稍后重试"
        case .network(let message): "网络错误：\(message)"
        case .invalidResponse(let message): "响应格式已变化：\(message)"
        case .executionFailed(let message): "命令执行失败：\(message)"
        case .permissionDenied(let message): "权限不足：\(message)"
        case .unknown(let message): message
        }
    }

    public static func map(_ error: Error) -> QuotaError {
        if let quotaError = error as? QuotaError { return quotaError }
        return .unknown(error.localizedDescription)
    }
}
