import AppKit
import Observation
import PortifoBarCore

// The app's state as its views see it, and everything they can do: the
// popover, the settings window and the menu bar all work through here.
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case live, connecting, reconnecting, paused, rateLimited, unreachable
    }

    enum AddResult: Equatable {
        case added(String), notFound, failed
    }

    let settings: Settings
    let chart = ChartModel()
    // The store's quotes, mirrored here so views redraw as they change.
    private(set) var quotes: [String: Quote] = [:]
    private(set) var status: Status = .connecting

    @ObservationIgnored let store: QuoteStore
    @ObservationIgnored private let client = YahooClient()
    // For the menu bar, which isn't a SwiftUI view.
    @ObservationIgnored var onQuote: (String) -> Void = { _ in }
    @ObservationIgnored var onSettingsChange: () -> Void = {}
    @ObservationIgnored var onOpenSettings: () -> Void = {}

    init(store: QuoteStore, settings: Settings) {
        self.store = store
        self.settings = settings
        chart.quoteFor = { [weak store] in store?.quotes[$0] }
        chart.onSnapshot = { [weak store] in store?.ingest($0) }
        chart.range = settings.chartRange
        chart.bandsOn = settings.smaBands
        store.onUpdate = { [weak self] symbol, _ in self?.quoteChanged(symbol) }
        store.onStatusChange = { [weak self] in self?.updateStatus() }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        store.track(settings.symbols)
    }

    // The symbol to chart when the popover opens: the one last charted,
    // else the first in the menu bar.
    func prepareChart() {
        if !settings.symbols.contains(chart.symbol) {
            chart.symbol = settings.menuBar.first ?? settings.symbols.first ?? ""
        }
    }

    func select(_ symbol: String) {
        chart.symbol = symbol
    }

    func isPinned(_ symbol: String) -> Bool {
        settings.pinned.contains(symbol)
    }

    func togglePinned(_ symbol: String) {
        if isPinned(symbol) {
            settings.pinned.removeAll { $0 == symbol }
        } else {
            settings.pinned.append(symbol)
        }
    }

    func remove(_ symbol: String) {
        settings.pinned.removeAll { $0 == symbol }
        settings.symbols.removeAll { $0 == symbol }
    }

    // Takes the symbol as typed if Yahoo prices it, else the best match
    // for it as a name ("shopify" → SHOP), and charts it.
    func add(_ query: String) async -> AddResult {
        do {
            let typed = query.uppercased()
            var symbol: String?
            if !typed.contains(" ") {
                symbol = try await client.snapshots(for: [typed], bars: false).first?.symbol
            }
            if symbol == nil {
                symbol = try await client.search(query).first?.symbol
            }
            guard let symbol else { return .notFound }
            if !settings.symbols.contains(symbol) { settings.symbols.append(symbol) }
            if settings.menuBar.isEmpty { settings.pinned = [symbol] }
            select(symbol)
            return .added(symbol)
        } catch {
            return .failed
        }
    }

    func openOnYahoo(_ symbol: String) {
        NSWorkspace.shared.open(YahooClient.page(for: symbol))
    }

    func openSettings() {
        onOpenSettings()
    }

    private func quoteChanged(_ symbol: String) {
        let quote = store.quotes[symbol]
        quotes[symbol] = quote
        if let quote, symbol == chart.symbol { chart.update(quote) }
        onQuote(symbol)
    }

    private func settingsChanged() {
        store.track(settings.symbols)
        quotes = quotes.filter { settings.symbols.contains($0.key) }
        if !settings.symbols.contains(chart.symbol) { prepareChart() }
        chart.range = settings.chartRange
        chart.bandsOn = settings.smaBands
        onSettingsChange()
    }

    private func updateStatus() {
        if let error = store.lastError {
            status = error == .rateLimited ? .rateLimited : .unreachable
            return
        }
        switch store.streamState {
        case .live: status = .live
        case .connecting: status = .connecting
        case .retrying: status = .reconnecting
        case .idle: status = .paused
        }
    }
}
