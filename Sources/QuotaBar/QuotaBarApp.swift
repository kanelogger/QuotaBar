import SwiftUI
import QuotaCore

@main
struct QuotaBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(model: model)
        } label: {
            StatusLabel(summary: model.summary, hasData: !model.updates.isEmpty)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 460)
        }
    }
}

private struct StatusLabel: View {
    let summary: QuotaSummary?
    let hasData: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text(label)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
        }
        .accessibilityLabel(accessibilityText)
    }

    private var label: String {
        guard let summary else { return hasData ? "!" : "--" }
        return "\(summary.providerID.shortName) \(summary.displayValue)"
    }

    private var iconName: String {
        guard let summary else { return hasData ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent" }
        return switch summary.health {
        case .healthy: "circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    private var accessibilityText: String {
        guard let summary else { return L10n.noData }
        return "\(summary.providerID.displayName), \(summary.displayValue)"
    }
}
