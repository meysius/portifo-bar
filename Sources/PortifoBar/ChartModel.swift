import Foundation
import Observation
import PortifoBarCore

// The popover's chart: one symbol over one range, fetched when the popover
// opens and again while it stays open (each minute for the day or the week,
// every five for longer), with each live quote folded into the last bar in
// between. With the SMA bands on, the symbol's daily closes too, which the
// 200-day average is taken over. The view builds the line.
@MainActor
@Observable
final class ChartModel {
    var symbol = "" {
        didSet {
            guard symbol != oldValue else { return }
            cache = [:]
            series = nil
            failed = false
            selection = nil
            closesFetch?.cancel()
            (closes, closesFrom, closesFetched, closesPending) = (nil, nil, nil, nil)
            quote = quoteFor(symbol)
            if visible { load() }
        }
    }
    var range: ChartRange = .day {
        didSet {
            guard range != oldValue else { return }
            // What this range showed last, if anything, while it refreshes.
            series = cache[range]
            failed = false
            selection = nil
            if visible { refresh() }
        }
    }
    // Whether the SMA bands are drawn. The daily closes are fetched only
    // while they are.
    var bandsOn = false {
        didSet {
            guard bandsOn != oldValue else { return }
            if bandsOn, visible { loadCloses() }
        }
    }
    // The point under the pointer or the keyboard's cursor.
    var selection: Int?
    private(set) var series: CandleSeries? {
        didSet { cache[range] = series }
    }
    private(set) var quote: Quote?
    private(set) var failed = false
    // Whether the popover is open: the chart takes the keyboard each time it is.
    private(set) var visible = false

    @ObservationIgnored var quoteFor: (String) -> Quote? = { _ in nil }
    // The chart's own snapshot, for the store: the freshest price there is
    // for the symbol on screen.
    @ObservationIgnored var onSnapshot: (Snapshot) -> Void = { _ in }
    @ObservationIgnored private let client = YahooClient()
    @ObservationIgnored private var fetch: Task<Void, Never>?
    @ObservationIgnored private var refresher: Task<Void, Never>?
    // The symbol's other ranges as last fetched, so switching back to one
    // shows it at once.
    @ObservationIgnored private var cache: [ChartRange: CandleSeries] = [:]
    // The symbol's daily closes, oldest first, for the moving average. One
    // fetch serves every range it reaches back far enough for, and stands
    // for five minutes: in that time the average moves by a 200th of the
    // price's move.
    private var closes: [DailyClose]?
    @ObservationIgnored private var closesFrom: Date?
    @ObservationIgnored private var closesFetched: Date?
    // How far back the fetch in flight reaches.
    @ObservationIgnored private var closesPending: Date?
    @ObservationIgnored private var closesFetch: Task<Void, Never>?
    private static let closesStandFor: TimeInterval = 300

    func start() {
        visible = true
        quote = quoteFor(symbol)
        refresh()
    }

    func stop() {
        visible = false
        refresher?.cancel()
        fetch?.cancel()
        selection = nil
    }

    // Fetches now, and again at the range's pace.
    private func refresh() {
        refresher?.cancel()
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                guard let every = self?.range.refreshEvery else { return }
                self?.load()
                try? await Task.sleep(for: every)
            }
        }
    }

    func load() {
        guard !symbol.isEmpty else { return }
        loadCloses()
        fetch?.cancel()
        let (symbol, range, client) = (self.symbol, self.range, self.client)
        fetch = Task { [weak self] in
            let result = await Task.detached { try? await client.chart(for: symbol, range: range) }.value
            guard let self, !Task.isCancelled, symbol == self.symbol, range == self.range else { return }
            // Folding it in brings `quote` up to date through `update`.
            if let snapshot = result?.snapshot { self.onSnapshot(snapshot) }
            guard var series = result?.series else {
                // Keep what's on screen through a failed refresh.
                self.failed = self.series == nil
                return
            }
            if let quote = self.quote { series.update(with: quote) }
            self.series = series
            self.failed = false
            self.loadCloses()
        }
    }

    // The daily closes, if they reach back far enough to give `series`'s
    // first point a full window. Until they do, no bands: drawn from too few,
    // the average would start late and the scale jump when the rest arrive.
    func closes(covering series: CandleSeries) -> [DailyClose]? {
        guard bandsOn, let closes, let closesFrom, let first = series.bars.first?.time,
              closesFrom <= MovingAverage.closesStart(for: first)
        else { return nil }
        return closes
    }

    // Fetches the daily closes the chart on screen needs, unless those held
    // are fresh and reach back far enough, or a fetch on its way does.
    private func loadCloses() {
        guard bandsOn, !symbol.isEmpty, let first = series?.bars.first?.time else { return }
        let from = MovingAverage.closesStart(for: first)
        if let closesFrom, closesFrom <= from, let closesFetched,
           Date.now.timeIntervalSince(closesFetched) < Self.closesStandFor { return }
        if let closesPending, closesPending <= from { return }
        closesFetch?.cancel()
        closesPending = from
        let (symbol, client) = (self.symbol, self.client)
        closesFetch = Task { [weak self] in
            let result = await Task.detached { try? await client.dailyCloses(for: symbol, from: from) }.value
            guard let self, !Task.isCancelled, symbol == self.symbol else { return }
            self.closesPending = nil
            // A failed fetch keeps what's there; the next refresh tries again.
            guard let result else { return }
            self.closes = result
            self.closesFrom = from
            self.closesFetched = .now
        }
    }

    func update(_ quote: Quote) {
        guard quote.symbol == symbol else { return }
        self.quote = quote
        guard var series else { return }
        series.update(with: quote)
        if series != self.series { self.series = series }
    }
}
