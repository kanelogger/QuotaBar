import AppKit
import SwiftUI
import QuotaCore

struct PopoverContentView: View {
    @ObservedObject var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 14) {
            header
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(ProviderID.allCases, id: \.self) { providerID in
                    ProviderCardView(
                        providerID: providerID,
                        update: model.updates[providerID],
                        isRefreshing: model.isRefreshing,
                        thresholds: model.settings.thresholds,
                        unavailableAction: unavailableAction(for: providerID)
                    )
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 520)
        .sheet(isPresented: $model.settingsPresented) {
            SettingsView(model: model)
                .frame(width: 460)
        }
    }

    private func unavailableAction(for providerID: ProviderID) -> (() -> Void)? {
        guard providerID == .kimi else { return nil }
        return { model.openKimiSubscription() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("QuotaBar")
                    .font(.headline)
                Text(L10n.overviewSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(model.isRefreshing ? .degrees(360) : .zero)
                    .animation(
                        model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: model.isRefreshing
                    )
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(L10n.refresh)
            .accessibilityLabel(L10n.refresh)

            Button {
                model.settingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.settings)
            .accessibilityLabel(L10n.settings)
        }
    }

    private var footer: some View {
        HStack {
            if let summary = model.summary {
                Label(
                    "\(L10n.mostUrgent): \(summary.providerID.displayName) \(summary.displayValue)",
                    systemImage: summary.health == .critical ? "exclamationmark.triangle.fill" : "checkmark.circle"
                )
                .foregroundStyle(summary.health == .critical ? Color.red : Color.secondary)
            } else {
                Text(L10n.noData)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.quit) { model.quit() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct ProviderCardView: View {
    let providerID: ProviderID
    let update: ProviderUpdate?
    let isRefreshing: Bool
    let thresholds: BalanceThresholds
    let unavailableAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                providerIcon
                Text(providerID.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if update?.snapshot?.isStale == true {
                    Text(L10n.stale)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if let snapshot = update?.snapshot {
                if case .unavailable(let message) = snapshot.status {
                    Label(
                        providerID == .deepSeek ? L10n.accountUnavailable : message,
                        systemImage: "nosign"
                    )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                ForEach(snapshot.metrics) { metric in
                    MetricRow(
                        metric: metric,
                        thresholds: thresholds,
                        unavailableAction: unavailableAction
                    )
                }
                Text(timestamp(snapshot.capturedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let error = update?.error {
                errorView(error)
            } else {
                HStack(spacing: 6) {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    Text(isRefreshing ? L10n.loading : L10n.waitingForRefresh)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
            }

            if let error = update?.error, update?.snapshot != nil {
                Label(L10n.errorDescription(error), systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(providerID.displayName)
    }

    private var providerIcon: some View {
        let name: String = switch providerID {
        case .openCodeGo: "terminal"
        case .kimi: "moon.stars.fill"
        case .codex: "sparkles"
        case .deepSeek: "banknote.fill"
        }
        return Image(systemName: name)
            .frame(width: 20, height: 20)
            .foregroundStyle(.tint)
    }

    private func errorView(_ error: QuotaError) -> some View {
        Label(L10n.errorDescription(error), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
            .multilineTextAlignment(.center)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(L10n.updated) \(formatter.string(from: date))"
    }
}

private struct MetricRow: View {
    let metric: UsageMetric
    let thresholds: BalanceThresholds
    let unavailableAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localizedName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(valueColor)
            }

            if let percent = normalizedPercent, metric.availability == .available {
                ProgressView(value: percent, total: 100)
                    .tint(valueColor)
                    .accessibilityLabel(localizedName)
                    .accessibilityValue("\(Int(percent.rounded()))%")
            }

            if let resetsAt = metric.resetsAt {
                Text(relativeReset(resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if metric.availability == .available,
                      let message = metric.message,
                      !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if metric.availability == .unavailable,
                      metric.window == .monthly,
                      let unavailableAction {
                Button(L10n.openSubscription, action: unavailableAction)
                    .font(.caption2)
                    .buttonStyle(.link)
            }
        }
    }

    private var localizedName: String {
        switch metric.window {
        case .fiveHour: L10n.fiveHour
        case .weekly: L10n.weekly
        case .monthly: L10n.monthly
        case nil: metric.name
        }
    }

    private var valueText: String {
        if metric.availability == .unavailable { return L10n.unavailable }
        if let formattedBalance = metric.formattedBalance {
            return formattedBalance
        }
        if let percent = metric.percentRemaining {
            return "\(Int(percent.rounded()))% \(L10n.remaining)"
        }
        return "--"
    }

    private var valueColor: Color {
        guard let percent = normalizedPercent else { return .primary }
        return switch QuotaHealth.from(score: percent) {
        case .critical: .red
        case .warning: .orange
        case .healthy: .green
        }
    }

    private var normalizedPercent: Double? {
        metric.normalizedRemainingScore(thresholds: thresholds)
    }

    private func relativeReset(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "\(L10n.resets) \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
