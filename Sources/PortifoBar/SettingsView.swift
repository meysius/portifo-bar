import PortifoBarCore
import ServiceManagement
import SwiftUI

// The settings window: the watchlist and which of it shows in the menu bar,
// how the menu bar shows a price, and launching at login.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ForEach(settings.symbols, id: \.self) { symbol in
                    row(symbol)
                }
                AddSymbolField(model: model)
            } header: {
                Text("Watchlist")
            } footer: {
                Text("Symbols ticked for the menu bar show there, in this order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Picker("Beside the price", selection: $settings.changeStyle) {
                    ForEach(Settings.ChangeStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Flash green or red on every move", isOn: $settings.flash)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(Bundle.main.bundleIdentifier == nil)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginProblem {
                    Text(loginProblem).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "Prices from Yahoo Finance: streamed as they trade, and refreshed every "
                        + "\(Int(QuoteStore.tradingRefresh)) seconds while a market is open."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 460)
    }

    private func row(_ symbol: String) -> some View {
        HStack(spacing: 8) {
            Text(symbol).fontWeight(.semibold)
            Text(model.quotes[symbol]?.name ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Toggle("Menu bar", isOn: Binding(
                get: { model.isPinned(symbol) },
                set: { if $0 != model.isPinned(symbol) { model.togglePinned(symbol) } }
            ))
            .toggleStyle(.checkbox)
            Button {
                model.remove(symbol)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove \(symbol)")
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
            loginProblem = service.status == .requiresApproval
                ? "Allow Portifo Bar in System Settings › General › Login Items." : nil
        } catch {
            loginProblem = error.localizedDescription
            launchAtLogin = service.status == .enabled
        }
    }
}
