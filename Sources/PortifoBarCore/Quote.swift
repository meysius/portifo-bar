import Foundation

public enum Session: String, Sendable {
    // Overnight is 8 PM to 4 AM New York, between one day's after hours and
    // the next day's pre-market. Only the streamer has it: the chart
    // endpoints give no bars and no trading period for it.
    case pre, regular, post, overnight

    // Portifo's own words for those outside the regular session, and Yahoo's
    // for overnight.
    public var label: String? {
        switch self {
        case .pre: "Pre-market"
        case .post: "After hours"
        case .overnight: "Overnight"
        case .regular: nil
        }
    }
}

// One trading day's hours: pre-market from `preStart`, the regular session
// over `regularStart...regularEnd`, after hours until `postEnd`. Yahoo sends
// the windows even for listings that never trade in the outer two (Toronto,
// London); for crypto and FX the regular session is the whole day.
public struct TradingDay: Sendable, Equatable {
    public var preStart: Date
    public var regularStart: Date
    public var regularEnd: Date
    public var postEnd: Date

    public init(preStart: Date, regularStart: Date, regularEnd: Date, postEnd: Date) {
        self.preStart = preStart
        self.regularStart = regularStart
        self.regularEnd = regularEnd
        self.postEnd = postEnd
    }
}

// A trade outside the regular session.
public struct ExtendedTrade: Sendable, Equatable {
    public var session: Session
    public var price: Double
    public var time: Date

    public init(session: Session, price: Double, time: Date) {
        self.session = session
        self.price = price
        self.time = time
    }
}

// What Yahoo's chart endpoints know about a symbol at one moment.
public struct Snapshot: Sendable, Equatable {
    public struct Bar: Sendable, Equatable {
        public var price: Double
        public var time: Date

        public init(price: Double, time: Date) {
            self.price = price
            self.time = time
        }
    }

    public var symbol: String
    public var name: String?
    public var currency: String?
    public var exchange: String?
    public var decimals: Int
    // The regular session's price and when it was struck.
    public var price: Double
    public var time: Date
    public var previousClose: Double?
    public var day: TradingDay?
    public var hasExtendedHours: Bool
    // The day's latest bar, extended hours included: the only place the
    // chart endpoints put a pre-market or after-hours price.
    public var lastBar: Bar?

    public init(
        symbol: String,
        name: String? = nil,
        currency: String? = nil,
        exchange: String? = nil,
        decimals: Int = 2,
        price: Double,
        time: Date,
        previousClose: Double? = nil,
        day: TradingDay? = nil,
        hasExtendedHours: Bool = false,
        lastBar: Bar? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.currency = currency
        self.exchange = exchange
        self.decimals = decimals
        self.price = price
        self.time = time
        self.previousClose = previousClose
        self.day = day
        self.hasExtendedHours = hasExtendedHours
        self.lastBar = lastBar
    }
}

// A symbol's price as streamed trades and polled snapshots leave it. As in
// Portifo, `price` stays the regular session's (its close, outside it), and
// a later trade outside the session sits beside it in `extended`.
public struct Quote: Sendable, Equatable {
    public let symbol: String
    public var name: String?
    public var currency: String?
    public var exchange: String?
    public var decimals: Int
    public var price: Double
    public var time: Date
    public var previousClose: Double?
    // The latest trade outside the regular session, while it's newer than `price`.
    public var extended: ExtendedTrade?
    public var day: TradingDay?
    // Whether the listing trades pre-market and after hours: US listings
    // mostly do; Toronto, London, crypto, FX and indices don't. Unknown until
    // a snapshot says.
    public var hasExtendedHours: Bool?

    public init(snapshot s: Snapshot) {
        symbol = s.symbol
        decimals = s.decimals
        price = s.price
        time = s.time
        apply(s)
    }

    // A quote from a trade alone, before any snapshot has arrived. Only a
    // regular-session trade will do: one outside it says nothing of the
    // regular price beside it.
    public init?(tick: Tick) {
        symbol = tick.symbol
        decimals = tick.decimals ?? 2
        price = tick.price
        time = tick.time
        guard session(at: tick.time, flag: tick.marketHours) == .regular else { return nil }
        name = tick.name
        currency = tick.currency
        exchange = tick.exchange
        previousClose = tick.change.map { tick.price - $0 }
    }

    // The figure to show: the latest trade, extended hours included, and its
    // move. In the regular session that's against the previous close; outside
    // it, against the regular close, as Yahoo and Portifo measure it.
    public struct Latest: Sendable, Equatable {
        public var price: Double
        public var change: Double?
        public var changePercent: Double?
        public var session: Session
        public var time: Date
    }

    public var latest: Latest {
        if let e = extended {
            let change = e.price - price
            return Latest(
                price: e.price,
                change: change,
                changePercent: price != 0 ? change / price * 100 : nil,
                session: e.session,
                time: e.time
            )
        }
        let change = previousClose.map { price - $0 }
        let percent = previousClose.flatMap { $0 != 0 ? (price - $0) / $0 * 100 : nil }
        return Latest(price: price, change: change, changePercent: percent, session: .regular, time: time)
    }

    // Which session a trade at `t` falls in. The day's windows decide while
    // `t` lies within them; past them (the day has rolled over and no snapshot
    // has said so yet), the streamer's own flag does.
    public func session(at t: Date, flag: Int?) -> Session {
        if hasExtendedHours == false { return .regular }
        if let day, t >= day.preStart, t < day.postEnd {
            // The close itself is struck at the session's end, so it counts as regular.
            return t < day.regularStart ? .pre : t <= day.regularEnd ? .regular : .post
        }
        switch flag {
        case 1?: return .regular
        case 2?, 3?: return .post
        case 0?: return .pre
        case 4?: return .overnight
        default: return .regular
        }
    }

    // Whether the listing trades at `date`, extended hours included. With
    // no day known, assume it might.
    public func isTrading(at date: Date) -> Bool {
        guard let day else { return true }
        let extendedHours = hasExtendedHours ?? false
        let start = extendedHours ? day.preStart : day.regularStart
        let end = extendedHours ? day.postEnd : day.regularEnd
        return date >= start && date <= end
    }

    // Whether `t` falls after the day this quote knows: the day has rolled
    // over, and a fresh snapshot should follow.
    public func isPastDay(_ t: Date) -> Bool {
        guard let day else { return false }
        return t >= day.postEnd
    }

    // Whether a streamed trade comes from a day after the one this quote
    // knows. An overnight trade, though past the day's end, belongs between
    // two days, and Yahoo doesn't roll its day over for one: asking after
    // each would poll spark every few seconds all night.
    public func opensNewDay(_ tick: Tick) -> Bool {
        isPastDay(tick.time) && session(at: tick.time, flag: tick.marketHours) != .overnight
    }

    // Folds in a streamed trade. One older than what's held is dropped: the
    // streamer and the snapshots race, and the newer of the two stands.
    public mutating func apply(_ tick: Tick) {
        if let d = tick.decimals { decimals = d }
        name = name ?? tick.name
        currency = currency ?? tick.currency
        exchange = exchange ?? tick.exchange
        switch session(at: tick.time, flag: tick.marketHours) {
        case .regular:
            guard tick.time >= time else { return }
            // A new regular session: the price held until now was the close before it.
            if opensNewSession(at: tick.time) { previousClose = price }
            price = tick.price
            time = tick.time
            if previousClose == nil, let change = tick.change { previousClose = tick.price - change }
        case let session:
            guard tick.time > time, tick.time >= (extended?.time ?? .distantPast) else { return }
            extended = ExtendedTrade(session: session, price: tick.price, time: tick.time)
        }
        dropStaleExtended()
    }

    // Folds in a snapshot. A snapshot of a day older than the quote's latest
    // trade (the REST feed lagging the streamer across midnight) can't speak
    // for today's previous close or hours, so it only fills gaps.
    public mutating func apply(_ s: Snapshot) {
        name = s.name ?? name
        currency = s.currency ?? currency
        exchange = s.exchange ?? exchange
        decimals = s.decimals
        let olderDay = s.day.map { time >= $0.postEnd } ?? false
        if !olderDay {
            day = s.day ?? day
            hasExtendedHours = s.hasExtendedHours
            previousClose = s.previousClose ?? previousClose
        }
        if s.time >= time {
            price = s.price
            time = s.time
        }
        if let bar = s.lastBar, bar.time > time, bar.time >= (extended?.time ?? .distantPast) {
            let session = session(at: bar.time, flag: nil)
            if session != .regular {
                extended = ExtendedTrade(session: session, price: bar.price, time: bar.time)
            }
        }
        dropStaleExtended()
    }

    private func opensNewSession(at t: Date) -> Bool {
        guard let day else { return false }
        return (time < day.regularStart && t >= day.regularStart) || (time < day.postEnd && t >= day.postEnd)
    }

    private mutating func dropStaleExtended() {
        if let e = extended, e.time <= time { extended = nil }
    }
}
