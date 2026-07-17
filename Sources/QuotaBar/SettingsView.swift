import SwiftUI
import QuotaCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @State private var deepSeekKey = ""
    @State private var kimiToken = ""

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.settings)
                    .font(.title2.weight(.semibold))
            }

            GroupBox(L10n.credentials) {
                VStack(alignment: .leading, spacing: 12) {
                    credentialRow(
                        title: "DeepSeek API Key",
                        text: $deepSeekKey,
                        providerID: .deepSeek
                    )
                    Divider()
                    credentialRow(
                        title: "Kimi kimi-auth",
                        text: $kimiToken,
                        providerID: .kimi
                    )
                    HStack {
                        Button(L10n.importBrowserCookie) {
                            model.importKimiBrowserCookie()
                        }
                        Text(L10n.fullDiskAccessHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox(L10n.balanceWarning) {
                HStack(spacing: 18) {
                    LabeledContent("CNY") {
                        TextField("10", value: $settings.cnyThreshold, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 74)
                            .onChange(of: settings.cnyThreshold) { _, _ in model.thresholdsChanged() }
                    }
                    LabeledContent("USD") {
                        TextField("2", value: $settings.usdThreshold, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 74)
                            .onChange(of: settings.usdThreshold) { _, _ in model.thresholdsChanged() }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox(L10n.refreshInterval) {
                Picker(L10n.refreshInterval, selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: settings.refreshInterval) { _, _ in model.refreshIntervalChanged() }
                .padding(.top, 4)
            }

            if let message = model.credentialMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func credentialRow(
        title: String,
        text: Binding<String>,
        providerID: ProviderID
    ) -> some View {
        let isConfigured = model.hasCredential(for: providerID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Label(
                    isConfigured ? L10n.configured : L10n.notConfigured,
                    systemImage: isConfigured ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption)
                .foregroundStyle(isConfigured ? Color.green : Color.secondary)
            }
            HStack {
                SecureField(L10n.pasteCredential, text: text)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.save) {
                    model.saveCredential(text.wrappedValue, for: providerID)
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.remove) {
                    model.saveCredential("", for: providerID)
                    text.wrappedValue = ""
                }
                .disabled(!isConfigured)
            }
        }
    }
}
