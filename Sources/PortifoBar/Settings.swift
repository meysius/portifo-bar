import Foundation
import Observation
import PortifoBarCore

// What the user has chosen, kept in UserDefaults and observed by the views
// that change it.
@MainActor
@Observable
final class Settings {
    enum ChangeStyle: String, CaseIterable, Identifiable {
        case percent, amount, none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .percent: "Percent change"
            case .amount: "Price change"
            case .none: "Price only"
            }
        }
    }

    private enum Key {
        static let symbols = "symbols"
        static let pinned = "pinned"
        static let changeStyle = "changeStyle"
        static let flash = "flashOnChange"
        static let chartRange = "chartRange"
        static let smaBands = "smaBands"
    }

    // The watchlist, in order.
    var symbols: [String] {
        didSet { save(symbols, Key.symbols) }
    }

    // Those shown in the menu bar; `menuBar` gives them in order.
    var pinned: [String] {
        didSet { save(pinned, Key.pinned) }
    }

    var changeStyle: ChangeStyle {
        didSet { save(changeStyle.rawValue, Key.changeStyle) }
    }

    // Tint a price for a moment when it moves: green up, red down.
    var flash: Bool {
        didSet { save(flash, Key.flash) }
    }

    // How far back the chart reaches.
    var chartRange: ChartRange {
        didSet { save(chartRange.rawValue, Key.chartRange) }
    }

    // Draw the 200-day average on the chart, with the bands about it that
    // the price crosses. Off until turned on, as in Portifo.
    var smaBands: Bool {
        didSet { save(smaBands, Key.smaBands) }
    }

    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.symbols: ["AAPL", "^GSPC", "BTC-USD"],
            Key.pinned: ["AAPL"],
            Key.changeStyle: ChangeStyle.percent.rawValue,
            Key.flash: true,
            Key.chartRange: ChartRange.day.rawValue,
            Key.smaBands: false,
        ])
        symbols = defaults.stringArray(forKey: Key.symbols) ?? []
        pinned = defaults.stringArray(forKey: Key.pinned) ?? []
        changeStyle = ChangeStyle(rawValue: defaults.string(forKey: Key.changeStyle) ?? "") ?? .percent
        flash = defaults.bool(forKey: Key.flash)
        chartRange = ChartRange(rawValue: defaults.string(forKey: Key.chartRange) ?? "") ?? .day
        smaBands = defaults.bool(forKey: Key.smaBands)
    }

    // The menu bar's symbols, in watchlist order.
    var menuBar: [String] {
        let chosen = Set(pinned)
        return symbols.filter(chosen.contains)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange()
    }
}
