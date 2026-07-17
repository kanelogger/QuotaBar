import Foundation
import QuotaCore

enum L10n {
    static var overviewSubtitle: String { text("overview.subtitle") }
    static var refresh: String { text("action.refresh") }
    static var settings: String { text("action.settings") }
    static var quit: String { text("action.quit") }
    static var done: String { text("action.done") }
    static var save: String { text("action.save") }
    static var remove: String { text("action.remove") }
    static var loading: String { text("state.loading") }
    static var waitingForRefresh: String { text("state.waiting") }
    static var stale: String { text("state.stale") }
    static var unavailable: String { text("state.unavailable") }
    static var noData: String { text("state.noData") }
    static var configured: String { text("state.configured") }
    static var notConfigured: String { text("state.notConfigured") }
    static var remaining: String { text("metric.remaining") }
    static var fiveHour: String { text("metric.fiveHour") }
    static var weekly: String { text("metric.weekly") }
    static var monthly: String { text("metric.monthly") }
    static var resets: String { text("metric.resets") }
    static var updated: String { text("metric.updated") }
    static var mostUrgent: String { text("metric.mostUrgent") }
    static var credentials: String { text("settings.credentials") }
    static var pasteCredential: String { text("settings.pasteCredential") }
    static var importBrowserCookie: String { text("settings.importCookie") }
    static var fullDiskAccessHint: String { text("settings.fullDiskAccess") }
    static var balanceWarning: String { text("settings.balanceWarning") }
    static var refreshInterval: String { text("settings.refreshInterval") }
    static var openSubscription: String { text("action.openSubscription") }
    static var saved: String { text("message.saved") }
    static var cookieImported: String { text("message.cookieImported") }
    static var oneMinute: String { text("interval.1m") }
    static var fiveMinutes: String { text("interval.5m") }
    static var fifteenMinutes: String { text("interval.15m") }
    static var thirtyMinutes: String { text("interval.30m") }
    static var accountUnavailable: String { text("state.accountUnavailable") }

    static func errorDescription(_ error: Error) -> String {
        guard let error = error as? QuotaError else { return error.localizedDescription }
        return switch error {
        case .cliNotFound(let name): String(format: text("error.cliNotFound"), name)
        case .notLoggedIn: text("error.notLoggedIn")
        case .notConfigured: text("error.notConfigured")
        case .authenticationExpired: text("error.authenticationExpired")
        case .rateLimited: text("error.rateLimited")
        case .network(let detail): String(format: text("error.network"), detail)
        case .invalidResponse(let detail): String(format: text("error.invalidResponse"), detail)
        case .executionFailed(let detail): String(format: text("error.executionFailed"), detail)
        case .permissionDenied(let detail): String(format: text("error.permissionDenied"), detail)
        case .unknown(let detail): detail
        }
    }

    private static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}
