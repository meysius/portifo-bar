import Foundation

// Every tracked symbol's quote, within half a minute of the market. Two
// feeds race and the newer trade wins:
//
// - the streamer, which pushes trades as Yahoo relays them: within a second
//   on a good day, though it has been seen running a minute behind, and some
//   symbols (^GSPC) never stream at all;
// - spark, a second or two behind the trade when asked, asked every 30
//   seconds for a symbol that's trading and every five minutes otherwise:
//   about 120 requests an hour while a market is open.
@MainActor
public final class QuoteStore {
    public enum Source: Sendable {
        case stream, poll
    }

    // How often each symbol is refreshed, trading and not; how often the
    // poller wakes to see what's due (a wake that finds nothing due costs
    // no request).
    public static let tradingRefresh: TimeInterval = 30
    public static let idleRefresh: TimeInterval = 300
    static let wakeEvery: Duration = .seconds(5)

    public private(set) var symbols: [String] = []
    public private(set) var quotes: [String: Quote] = [:]
    // When anything (a trade or a snapshot) last came in for each symbol.
    public private(set) var lastReceived: [String: Date] = [:]
    public private(set) var lastError: YahooError?
    // How far behind the trade the stream's latest frame arrived.
    public private(set) var streamLag: TimeInterval?
    public var streamState: YahooStreamer.State { streamer.state }

    public var onUpdate: (String, Source) -> Void = { _, _ in }
    public var onStatusChange: () -> Void = {}

    private let client: YahooClient
    private let streamer: YahooStreamer
    private var lastPolled: [String: Date] = [:]
    // Symbols to include in the next poll whatever their state: new ones,
    // and those whose day has rolled over.
    private var due: Set<String> = []
    private var backoffUntil = Date.distantPast
    private var rateLimits = 0
    private var poller: Task<Void, Never>?
    private var paused = false

    public init(client: YahooClient = YahooClient(), streamer: YahooStreamer = YahooStreamer()) {
        self.client = client
        self.streamer = streamer
        streamer.onTick = { [weak self] tick in self?.receive(tick) }
        streamer.onStateChange = { [weak self] _ in self?.onStatusChange() }
    }

    public func track(_ symbols: [String]) {
        self.symbols = symbols
        let wanted = Set(symbols)
        for gone in Set(quotes.keys).subtracting(wanted) {
            quotes[gone] = nil
            lastReceived[gone] = nil
            lastPolled[gone] = nil
        }
        due = due.intersection(wanted).union(wanted.subtracting(quotes.keys))
        streamer.track(wanted)
        if !paused { restartPolling() }
    }

    // Hangs up while nobody can see the menu bar: asleep, or the screens off.
    public func pause() {
        paused = true
        streamer.suspend()
        poller?.cancel()
        poller = nil
    }

    // Reconnects at once and refreshes everything.
    public func resume() {
        guard paused else { return }
        paused = false
        lastPolled = [:]
        backoffUntil = .distantPast
        streamer.reconnect()
        restartPolling()
    }

    // The network is back: no waiting out the stream's backoff.
    public func reconnect() {
        guard !paused else { return }
        lastPolled = [:]
        streamer.reconnect()
        restartPolling()
    }

    private func restartPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.wakeEvery)
            }
        }
    }

    private func poll() async {
        let now = Date.now
        guard !symbols.isEmpty, now >= backoffUntil else { return }
        let wanted = symbols.filter {
            due.contains($0) || now.timeIntervalSince(lastPolled[$0] ?? .distantPast) >= refreshInterval($0, at: now)
        }
        guard !wanted.isEmpty else { return }
        let withBars = wanted.filter { needsBars($0, at: now) }
        let withoutBars = wanted.filter { !needsBars($0, at: now) }
        do {
            var snapshots: [Snapshot] = []
            if !withBars.isEmpty { snapshots += try await client.snapshots(for: withBars, bars: true) }
            if !withoutBars.isEmpty { snapshots += try await client.snapshots(for: withoutBars, bars: false) }
            for symbol in wanted { lastPolled[symbol] = now }
            due.subtract(wanted)
            rateLimits = 0
            lastError = nil
            for snapshot in snapshots { merge(snapshot) }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch YahooError.rateLimited {
            // 30s, 1m, 2m… up to 5m. The stream carries on meanwhile.
            rateLimits += 1
            backoffUntil = now.addingTimeInterval(min(300, 30 * pow(2, Double(rateLimits - 1))))
            lastError = .rateLimited
        } catch let error as YahooError {
            lastError = error
        } catch {
            lastError = .invalidResponse
        }
        onStatusChange()
    }

    // A symbol Yahoo hasn't priced yet waits for `due` or the slow pace,
    // so one it doesn't know isn't asked about every few seconds.
    private func refreshInterval(_ symbol: String, at now: Date) -> TimeInterval {
        guard let quote = quotes[symbol], quote.isTrading(at: now) else { return Self.idleRefresh }
        return Self.tradingRefresh
    }

    // Bars carry the only pre-market and after-hours price spark has; in the
    // regular session they're dead weight.
    private func needsBars(_ symbol: String, at now: Date) -> Bool {
        guard let quote = quotes[symbol] else { return true }
        guard quote.hasExtendedHours != false, let day = quote.day else { return quote.hasExtendedHours != false }
        return now < day.regularStart || now > day.regularEnd
    }

    private func receive(_ tick: Tick) {
        let symbol = tick.symbol
        guard symbols.contains(symbol) else { return }
        let now = Date.now
        lastReceived[symbol] = now
        streamLag = max(0, now.timeIntervalSince(tick.time))
        if var quote = quotes[symbol] {
            if quote.opensNewDay(tick) { due.insert(symbol) }
            let before = quote
            quote.apply(tick)
            guard quote != before else { return }
            quotes[symbol] = quote
        } else if let quote = Quote(tick: tick) {
            quotes[symbol] = quote
            due.insert(symbol)
        } else {
            return
        }
        onUpdate(symbol, .stream)
    }

    // A snapshot fetched elsewhere (the chart's), folded in like a poll's.
    public func ingest(_ snapshot: Snapshot) {
        merge(snapshot)
    }

    private func merge(_ snapshot: Snapshot) {
        let symbol = snapshot.symbol
        guard symbols.contains(symbol) else { return }
        lastReceived[symbol] = .now
        let before = quotes[symbol]
        var quote = before ?? Quote(snapshot: snapshot)
        quote.apply(snapshot)
        guard quote != before else { return }
        quotes[symbol] = quote
        onUpdate(symbol, .poll)
    }
}
