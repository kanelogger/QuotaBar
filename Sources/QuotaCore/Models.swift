import Foundation

public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case openCodeGo
    case kimi
    case codex
    case deepSeek

    public var displayName: String {
        switch self {
        case .openCodeGo: "OpenCode Go"
        case .kimi: "Kimi"
        case .codex: "Codex"
        case .deepSeek: "DeepSeek"
        }
    }

    public var shortName: String {
        switch self {
        case .openCodeGo: "OC"
        case .kimi: "Kimi"
        case .codex: "GPT"
        case .deepSeek: "DS"
        }
    }
}

public enum UsageWindow: String, Codable, Sendable {
    case fiveHour
    case weekly
    case monthly
}

public enum MetricKind: String, Codable, Sendable {
    case quota
    case balance
}

public enum MetricAvailability: String, Codable, Sendable {
    case available
    case unavailable
}

public enum ProviderStatus: Equatable, Sendable {
    case ready
    case unavailable(String)
}

public struct UsageMetric: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: MetricKind
    public let window: UsageWindow?
    public let used: Double?
    public let total: Double?
    public let remaining: Double?
    public let balanceAmount: Decimal?
    public let percentRemaining: Double?
    public let unit: String
    public let resetsAt: Date?
    public let availability: MetricAvailability
    public let message: String?

    public init(
        id: String,
        name: String,
        kind: MetricKind,
        window: UsageWindow? = nil,
        used: Double? = nil,
        total: Double? = nil,
        remaining: Double? = nil,
        balanceAmount: Decimal? = nil,
        percentRemaining: Double? = nil,
        unit: String = "",
        resetsAt: Date? = nil,
        availability: MetricAvailability = .available,
        message: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.window = window
        self.used = used
        self.total = total
        self.remaining = remaining
        self.balanceAmount = balanceAmount
        self.percentRemaining = percentRemaining.map { max(0, min(100, $0)) }
        self.unit = unit
        self.resetsAt = resetsAt
        self.availability = availability
        self.message = message
    }

    public static func quota(
        id: String,
        name: String,
        window: UsageWindow,
        used: Double,
        total: Double,
        unit: String = "",
        resetsAt: Date? = nil
    ) -> UsageMetric {
        let normalizedUsed = max(0, used)
        let normalizedTotal = max(0, total)
        let remaining = max(0, normalizedTotal - normalizedUsed)
        let percent = normalizedTotal > 0 ? remaining / normalizedTotal * 100 : 100
        return UsageMetric(
            id: id,
            name: name,
            kind: .quota,
            window: window,
            used: normalizedUsed,
            total: normalizedTotal,
            remaining: remaining,
            percentRemaining: percent,
            unit: unit,
            resetsAt: resetsAt
        )
    }

    public static func percentageQuota(
        id: String,
        name: String,
        window: UsageWindow,
        percentRemaining: Double,
        resetsAt: Date? = nil,
        message: String? = nil
    ) -> UsageMetric {
        let normalizedPercent = max(0, min(100, percentRemaining))
        return UsageMetric(
            id: id,
            name: name,
            kind: .quota,
            window: window,
            used: 100 - normalizedPercent,
            total: 100,
            remaining: normalizedPercent,
            percentRemaining: normalizedPercent,
            unit: "%",
            resetsAt: resetsAt,
            message: message
        )
    }

    public static func balance(currency: String, amount: Double, message: String? = nil) -> UsageMetric {
        balance(currency: currency, decimalAmount: Decimal(amount), message: message)
    }

    public static func balance(currency: String, decimalAmount: Decimal, message: String? = nil) -> UsageMetric {
        UsageMetric(
            id: "balance-\(currency.lowercased())",
            name: "Balance",
            kind: .balance,
            remaining: NSDecimalNumber(decimal: decimalAmount).doubleValue,
            balanceAmount: decimalAmount,
            unit: currency.uppercased(),
            message: message
        )
    }

    public static func unavailable(
        id: String,
        name: String,
        window: UsageWindow?,
        message: String
    ) -> UsageMetric {
        UsageMetric(
            id: id,
            name: name,
            kind: .quota,
            window: window,
            availability: .unavailable,
            message: message
        )
    }

    public func normalizedRemainingScore(thresholds: BalanceThresholds) -> Double? {
        guard availability == .available else { return nil }
        if kind == .balance, let amount = remaining {
            return min(100, max(0, amount / thresholds.value(for: unit) * 100))
        }
        return percentRemaining
    }

    public var formattedBalance: String? {
        guard kind == .balance, let balanceAmount else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = unit.uppercased()
        formatter.locale = Locale(identifier: unit.uppercased() == "USD" ? "en_US_POSIX" : "zh_CN")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: balanceAmount))
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public let providerID: ProviderID
    public let metrics: [UsageMetric]
    public let capturedAt: Date
    public let source: String
    public let status: ProviderStatus
    public let isStale: Bool

    public init(
        providerID: ProviderID,
        metrics: [UsageMetric],
        capturedAt: Date,
        source: String,
        status: ProviderStatus = .ready,
        isStale: Bool = false
    ) {
        self.providerID = providerID
        self.metrics = metrics
        self.capturedAt = capturedAt
        self.source = source
        self.status = status
        self.isStale = isStale
    }

    public func markedStale() -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            metrics: metrics,
            capturedAt: capturedAt,
            source: source,
            status: status,
            isStale: true
        )
    }
}

public struct BalanceThresholds: Equatable, Sendable {
    public var cny: Double
    public var usd: Double

    public init(cny: Double, usd: Double) {
        self.cny = max(0.01, cny)
        self.usd = max(0.01, usd)
    }

    public static let defaults = BalanceThresholds(cny: 10, usd: 2)

    public func value(for currency: String) -> Double {
        currency.uppercased() == "USD" ? usd : cny
    }
}

public enum QuotaHealth: String, Sendable {
    case healthy
    case warning
    case critical

    public static func from(score: Double) -> QuotaHealth {
        if score < 10 { return .critical }
        if score < 50 { return .warning }
        return .healthy
    }
}

public struct QuotaSummary: Equatable, Sendable {
    public let providerID: ProviderID
    public let metricID: String
    public let score: Double
    public let displayValue: String
    public let health: QuotaHealth

    public static func make(
        snapshots: [ProviderID: ProviderSnapshot],
        thresholds: BalanceThresholds
    ) -> QuotaSummary? {
        let candidates = snapshots.values.flatMap { snapshot in
            guard snapshot.status == .ready else { return [QuotaSummary]() }
            return snapshot.metrics.compactMap { metric -> QuotaSummary? in
                guard let score = metric.normalizedRemainingScore(thresholds: thresholds) else {
                    return nil
                }

                if metric.kind == .balance,
                   let amount = metric.remaining {
                    return QuotaSummary(
                        providerID: snapshot.providerID,
                        metricID: metric.id,
                        score: score,
                        displayValue: metric.formattedBalance ?? String(format: "%.2f %@", amount, metric.unit),
                        health: .from(score: score)
                    )
                }

                return QuotaSummary(
                    providerID: snapshot.providerID,
                    metricID: metric.id,
                    score: score,
                    displayValue: "\(Int(score.rounded()))%",
                    health: .from(score: score)
                )
            }
        }
        return candidates.min { $0.score < $1.score }
    }
}
