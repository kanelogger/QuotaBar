import Foundation
import QuotaCore

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .oneMinute: L10n.oneMinute
        case .fiveMinutes: L10n.fiveMinutes
        case .fifteenMinutes: L10n.fifteenMinutes
        case .thirtyMinutes: L10n.thirtyMinutes
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let refreshInterval = "quotabar.refreshInterval"
        static let cnyThreshold = "quotabar.deepseek.cnyThreshold"
        static let usdThreshold = "quotabar.deepseek.usdThreshold"
    }

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval) }
    }
    @Published var cnyThreshold: Double {
        didSet { defaults.set(cnyThreshold, forKey: Key.cnyThreshold) }
    }
    @Published var usdThreshold: Double {
        didSet { defaults.set(usdThreshold, forKey: Key.usdThreshold) }
    }

    var thresholds: BalanceThresholds {
        BalanceThresholds(cny: cnyThreshold, usd: usdThreshold)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.integer(forKey: Key.refreshInterval)
        self.refreshInterval = RefreshInterval(rawValue: interval) ?? .fiveMinutes
        let cny = defaults.double(forKey: Key.cnyThreshold)
        let usd = defaults.double(forKey: Key.usdThreshold)
        self.cnyThreshold = cny > 0 ? cny : BalanceThresholds.defaults.cny
        self.usdThreshold = usd > 0 ? usd : BalanceThresholds.defaults.usd
    }
}
