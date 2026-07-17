import AppKit
import Combine
import Foundation
import OSLog
import QuotaCore

@MainActor
final class AppModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.kanelogger.QuotaBar", category: "refresh")

    @Published private(set) var updates: [ProviderID: ProviderUpdate] = [:]
    @Published private(set) var summary: QuotaSummary?
    @Published private(set) var isRefreshing = false
    @Published var settingsPresented = false
    @Published var credentialMessage: String?
    @Published private(set) var configuredProviders: Set<ProviderID> = []

    let settings: AppSettings
    let credentials: any CredentialStoring

    private let coordinator: QuotaCoordinator
    private var timer: Timer?
    private var started = false
    private var refreshPending = false
    private var wakeObserver: NSObjectProtocol?

    convenience init() {
        self.init(
            settings: AppSettings(),
            credentials: KeychainCredentialStore(),
            coordinator: nil
        )
    }

    init(
        settings: AppSettings,
        credentials: any CredentialStoring,
        coordinator: QuotaCoordinator?
    ) {
        self.settings = settings
        self.credentials = credentials
        if let coordinator {
            self.coordinator = coordinator
        } else {
            let kimiCredentials = KimiCredentialProvider(keychain: credentials)
            self.coordinator = QuotaCoordinator(probes: [
                OpenCodeProbe(),
                KimiUsageProbe(credentials: kimiCredentials),
                CodexProbe(),
                DeepSeekProbe(credentials: credentials),
            ])
        }
        refreshConfiguredProviders()
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }

        repeat {
            isRefreshing = true
            refreshPending = false
            updates = await coordinator.refreshAll { [weak self] providerID, update in
                await self?.apply(update, for: providerID)
            }
            recalculateSummary()
            isRefreshing = false
        } while refreshPending
    }

    func thresholdsChanged() {
        recalculateSummary()
    }

    func refreshIntervalChanged() {
        scheduleTimer()
    }

    func saveCredential(_ value: String, for providerID: ProviderID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try credentials.delete(for: providerID)
            } else {
                try credentials.set(trimmed, for: providerID)
            }
            refreshConfiguredProviders()
            credentialMessage = L10n.saved
            Task { await refresh() }
        } catch {
            credentialMessage = L10n.errorDescription(error)
        }
    }

    func hasCredential(for providerID: ProviderID) -> Bool {
        configuredProviders.contains(providerID)
    }

    func importKimiBrowserCookie() {
        do {
            let token = try KimiBrowserCookieImporter().resolveToken()
            try credentials.set(token, for: .kimi)
            refreshConfiguredProviders()
            credentialMessage = L10n.cookieImported
            Task { await refresh() }
        } catch {
            credentialMessage = L10n.errorDescription(error)
        }
    }

    func openKimiSubscription() {
        guard let url = URL(string: "https://www.kimi.com/code/console") else { return }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard started else { return }
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval.seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func recalculateSummary() {
        let snapshots = updates.compactMapValues(\.snapshot)
        summary = QuotaSummary.make(snapshots: snapshots, thresholds: settings.thresholds)
    }

    private func apply(_ update: ProviderUpdate, for providerID: ProviderID) {
        updates[providerID] = update
        recalculateSummary()
        if let error = update.error {
            let code = Self.errorCode(error)
            let stale = update.snapshot != nil
            Self.logger.error(
                "Provider \(providerID.rawValue, privacy: .public) failed with \(code, privacy: .public); stale=\(stale, privacy: .public)"
            )
        } else {
            let metricCount = update.snapshot?.metrics.count ?? 0
            Self.logger.info(
                "Provider \(providerID.rawValue, privacy: .public) succeeded with \(metricCount, privacy: .public) metrics"
            )
        }
    }

    private static func errorCode(_ error: QuotaError) -> String {
        switch error {
        case .cliNotFound: "cliNotFound"
        case .notLoggedIn: "notLoggedIn"
        case .notConfigured: "notConfigured"
        case .authenticationExpired: "authenticationExpired"
        case .rateLimited: "rateLimited"
        case .network: "network"
        case .invalidResponse(let detail):
            detail.hasPrefix("Kimi contract ") ? detail : "invalidResponse"
        case .executionFailed: "executionFailed"
        case .permissionDenied: "permissionDenied"
        case .unknown: "unknown"
        }
    }

    private func refreshConfiguredProviders() {
        configuredProviders = Set([ProviderID.kimi, .deepSeek].filter {
            (try? credentials.credential(for: $0))?.isEmpty == false
        })
    }
}
