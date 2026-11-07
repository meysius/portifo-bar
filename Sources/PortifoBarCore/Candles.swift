import Foundation

public struct Candle: Sendable, Equatable {
    // The start of the candle's period.
    public var time: Date
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    // The session the candle opened in.
    public var session: Session
    // Shares traded, where Yahoo reports it: never outside the regular
    // session, and not yet for a minute only a live quote has touched.
    public var volume: Double?

    public init(time: Date, open: Double, high: Double, low: Double, close: Double, session: Session = .regular, volume: Double? = nil) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.session = session
        self.volume = volume
    }

    public var isUp: Bool { close >= open }
}

// What one bar spans: some minutes, counted from the regular open of the
// day it falls in, or a day, a week (from Monday), a month, a quarter or a
// year on the exchange's own calendar.
public enum CandleSpan: Hashable, Sendable {
    case minutes(Int)
    case day, week, month, quarter, year

    // For "Daily closes", "5-minute closes".
    public var name: String {
        switch self {
        case .minutes(let m) where m % 60 == 0: "\(m / 60)-hour"
        case .minutes(let m): "\(m)-minute"
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        case .quarter: "Quarterly"
        case .year: "Yearly"
        }
    }

    public var isIntraday: Bool {
        if case .minutes = self { true } else { false }
    }

    // How long it lasts: exactly for minutes, and roughly beyond, enough to
    // put spans in order.
    public var length: TimeInterval {
        switch self {
        case .minutes(let m): TimeInterval(m * 60)
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 91 * 86_400
        case .year: 365 * 86_400
        }
    }

    // Yahoo's `dataGranularity`: "1m", "15m", "1h", "1d", "1wk", "1mo", "3mo".
    init?(granularity: String) {
        switch granularity {
        case "1d": self = .day
        case "5d", "1wk": self = .week
        case "1mo": self = .month
        case "3mo": self = .quarter
        default:
            if granularity.hasSuffix("m"), let m = Int(granularity.dropLast()) {
                self = .minutes(m)
            } else if granularity.hasSuffix("h"), let h = Int(granularity.dropLast()) {
                self = .minutes(h * 60)
            } else {
                return nil
            }
        }
    }
}

// How far back the chart reaches: the day, or a range of days. Each is drawn
// as Portifo draws it, one line through each bar's close, in the bars Portifo
// asks Yahoo for.
public enum ChartRange: String, CaseIterable, Sendable, Identifiable {
    case day = "1D"
    case week = "1W"
    case month = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case year = "1Y"
    case twoYears = "2Y"
    case fiveYears = "5Y"
    case all = "All"

    public var id: String { rawValue }
    public var label: String { rawValue }

    // For VoiceOver: "AAPL over the past year".
    public var phrase: String {
        switch self {
        case .day: "today"
        case .week: "over the past week"
        case .month: "over the past month"
        case .threeMonths: "over the past 3 months"
        case .sixMonths: "over the past 6 months"
        case .year: "over the past year"
        case .twoYears: "over the past 2 years"
        case .fiveYears: "over the past 5 years"
        case .all: "over all time"
        }
    }

    public var spoken: String {
        switch self {
        case .day: "1 day"
        case .week: "1 week"
        case .month: "1 month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .year: "1 year"
        case .twoYears: "2 years"
        case .fiveYears: "5 years"
        case .all: "All time"
        }
    }

    // The chart endpoint's query: two days' minutes with their pre-market
    // and after hours, which the day is cut from (see ChartJSON.series), and
    // beyond it the regular session's bars, as Portifo has them. A week asks for seven trading days and keeps the last seven
    // calendar days of them: five for a stock, seven for crypto. A month is
    // hourly, as Apple Stocks draws one: daily closes give ~21 points, which
    // read as a jagged polyline. All time asks from 1900 rather than
    // `range=max`, for which Yahoo turns a long history's months into
    // quarters of its own (March, June…).
    func query(at now: Date) -> String {
        switch self {
        case .day: "range=2d&interval=1m&includePrePost=true"
        case .week: "range=7d&interval=15m"
        case .month: "range=1mo&interval=60m"
        case .threeMonths: "range=3mo&interval=1d"
        case .sixMonths: "range=6mo&interval=1d"
        case .year: "range=1y&interval=1d"
        case .twoYears: "range=2y&interval=1wk"
        case .fiveYears: "range=5y&interval=1wk"
        case .all: "period1=-2208988800&period2=\(Int(now.timeIntervalSince1970))&interval=1mo"
        }
    }

    // What the query's bars span, should Yahoo not say.
    var base: CandleSpan {
        switch self {
        case .day: .minutes(1)
        case .week: .minutes(15)
        case .month: .minutes(60)
        case .threeMonths, .sixMonths, .year: .day
        case .twoYears, .fiveYears: .week
        case .all: .month
        }
    }

    // Whether its bars run into pre-market and after hours: the day's alone.
    public var includesExtendedHours: Bool { self == .day }

    // How often the chart refetches while it's on screen. Live quotes keep
    // the last bar current in between, so the long ranges can wait.
    public var refreshEvery: Duration {
        switch self {
        case .day, .week: .seconds(60)
        default: .seconds(300)
        }
    }
}

// One symbol's chart: the day in one-minute bars (pre-market and after hours
// included), or a longer range in Yahoo's bars for it, kept current between
// fetches by folding each new quote into the last bar. The day's line runs
// through five-minute bars built from its minutes, which keep its volume
// repairable and its last bar live.
//
// The day is the last trading day, not the last 24 hours, and it turns over
// at the regular open rather than at 4 AM: until then it is the day before,
// pre-market to after hours, with today's pre-market after it. A morning's
// look shows yesterday's move, with today's trading so far at its end,
// rather than a few hours of thin pre-market stretched across the chart. A
// market that never closes for the night (crypto, currencies, futures) has no
// day to keep: it shows the last 24 hours.
public struct CandleSeries: Sendable, Equatable {
    public var symbol: String
    public private(set) var bars: [Candle] = []
    // What the chart measures against: the close before the day's regular
    // session, the price 24 hours ago for a market that never closes, or the
    // close before a longer range began. See `reference(at:)`.
    public var previousClose: Double?
    // The last regular session's close once it has closed, and when its
    // trading day ends: the trades after that day (overnight, and the next
    // day's pre-market before the open) are measured against it.
    public var lastClose: LastClose?
    // Whether the day is the last 24 hours, for a market that never closes.
    public var isLast24Hours: Bool
    public var decimals: Int
    // The exchange's own clock.
    public var timeZone: TimeZone
    // The newest trade the bars include.
    public var asOf: Date
    // The trading day, and whether the bars run into its pre-market and
    // after hours.
    public var day: TradingDay?
    public var extendedHours: Bool
    public var range: ChartRange
    // What each bar spans.
    public var base: CandleSpan
    // Every day the bars cover, for a range of intraday bars: where each
    // day's candles are counted from, and which session a bar falls in.
    public var days: [TradingDay]

    public init(
        symbol: String,
        bars: [Candle],
        previousClose: Double? = nil,
        decimals: Int = 2,
        timeZone: TimeZone = .current,
        asOf: Date? = nil,
        day: TradingDay? = nil,
        extendedHours: Bool = false,
        range: ChartRange = .day,
        base: CandleSpan = .minutes(1),
        days: [TradingDay]? = nil,
        lastClose: LastClose? = nil,
        isLast24Hours: Bool = false
    ) {
        self.symbol = symbol
        self.previousClose = previousClose
        self.lastClose = lastClose
        self.isLast24Hours = isLast24Hours
        self.decimals = decimals
        self.timeZone = timeZone
        self.asOf = asOf ?? bars.last?.time ?? .distantPast
        self.day = day
        self.extendedHours = extendedHours
        self.range = range
        self.base = base
        self.days = days ?? day.map { [$0] } ?? []
        // Yahoo ends with a live point beside the bar it belongs to (10:39:20
        // after the 10:39 bar; today, after this week's bar): fold it in.
        for bar in bars { fold(bar) }
    }

    public struct LastClose: Sendable, Equatable {
        public var close: Double
        // When the session's trading day ends: its after hours' end.
        public var dayEnd: Date

        public init(close: Double, dayEnd: Date) {
            self.close = close
            self.dayEnd = dayEnd
        }
    }

    // What a point at `t` is measured against: the close before its own
    // day's session, or for a trade after the last session's day (overnight,
    // or the next day's pre-market), that session's close, as the price
    // above the chart measures it.
    public func reference(at t: Date) -> Double? {
        if let lastClose, t >= lastClose.dayEnd { return lastClose.close }
        return previousClose
    }

    // Whether the bars run over more than one calendar day: the day before
    // the open, with today's pre-market after it, or the last 24 hours.
    public var spansDays: Bool {
        guard let first = bars.first, let last = bars.last else { return false }
        return !calendar.isDate(first.time, inSameDayAs: last.time)
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Weeks from Monday, as Yahoo's weekly bars run.
        calendar.firstWeekday = 2
        return calendar
    }

    // The bars, merged into bars of `span`.
    public func candles(_ span: CandleSpan) -> [Candle] {
        guard span != base else { return bars }
        var candles: [Candle] = []
        for bar in bars {
            let start = start(of: bar.time, span)
            if let last = candles.last, last.time == start {
                candles[candles.count - 1] = merged(last, bar, volume: +)
            } else {
                var opened = bar
                opened.time = start
                candles.append(opened)
            }
        }
        return candles
    }

    // What each point on the line spans: five minutes of the day, as Portifo
    // draws it, or a longer range's own bars.
    public var lineSpan: CandleSpan {
        range == .day ? .minutes(5) : base
    }

    // The points the line runs through. Yahoo's chart has no overnight bars
    // (8 PM to 4 AM), so overnight the day's line ends on the latest trade,
    // one point past its after hours.
    public func line(through quote: Quote?) -> [Candle] {
        var points = candles(lineSpan)
        guard range == .day, extendedHours, let quote, quote.symbol == symbol else { return points }
        let latest = quote.latest
        if latest.session == .overnight, let last = points.last, latest.time > last.time {
            points.append(Candle(time: latest.time, open: latest.price, high: latest.price, low: latest.price, close: latest.price, session: .overnight))
        }
        return points
    }

    // When an intraday bar of `span` from `t` ends: its length on, or the
    // regular session's close where the bars stop there and it comes first
    // (an hour from 3:30 ends at 4:00).
    public func end(of t: Date, _ span: CandleSpan) -> Date {
        let end = t.addingTimeInterval(span.length)
        guard !extendedHours, let day = tradingDay(at: t), t < day.regularEnd else { return end }
        return min(end, day.regularEnd)
    }

    // The start of the `span` that `t` falls in.
    public func start(of t: Date, _ span: CandleSpan) -> Date {
        let calendar = calendar
        switch span {
        case .minutes(let m):
            var t = t
            let day = tradingDay(at: t)
            // The closing print, struck as the day's trading ends (16:00 for
            // a listing with no after hours), belongs to the day's last
            // candle rather than opening one past it.
            if let day, t == (extendedHours ? day.postEnd : day.regularEnd) { t -= 1 }
            return periodStart(t, TimeInterval(m * 60), anchor: day?.regularStart)
        case .day:
            return calendar.startOfDay(for: t)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: t)?.start ?? t
        case .month:
            return calendar.dateInterval(of: .month, for: t)?.start ?? t
        case .quarter:
            let c = calendar.dateComponents([.year, .month], from: t)
            let month = ((c.month ?? 1) - 1) / 3 * 3 + 1
            return calendar.date(from: DateComponents(year: c.year, month: month)) ?? t
        case .year:
            return calendar.dateInterval(of: .year, for: t)?.start ?? t
        }
    }

    // The start of the `step`-long period `t` falls in. Periods are counted
    // from the regular session's open, so no bar straddles it.
    private func periodStart(_ t: Date, _ step: TimeInterval, anchor: Date?) -> Date {
        let anchor = anchor ?? Date(timeIntervalSince1970: 0)
        return anchor.addingTimeInterval((t.timeIntervalSince(anchor) / step).rounded(.down) * step)
    }

    // The day `t` falls in, or the last to begin before it.
    private func tradingDay(at t: Date) -> TradingDay? {
        days.last { $0.preStart <= t } ?? day
    }

    // Folds the quote's latest trade into the last bar, or opens a new one
    // when a new period has begun: any trade where the bars run into extended
    // hours, and the regular session's alone where they don't. A trade outside
    // the day (overnight, or the next day's before a fetch brings it) has no
    // place among intraday bars: it would stretch the axis past the day's end,
    // leaving hours of gap before a lone candle.
    public mutating func update(with quote: Quote) {
        guard quote.symbol == symbol, !bars.isEmpty else { return }
        let (price, time, session): (Double, Date, Session)
        if extendedHours {
            let latest = quote.latest
            (price, time, session) = (latest.price, latest.time, latest.session)
        } else {
            (price, time, session) = (quote.price, quote.time, .regular)
        }
        if base.isIntraday, let day, time < day.preStart || time >= day.postEnd { return }
        guard time >= asOf else { return }
        asOf = time
        fold(Candle(time: time, open: price, high: price, low: price, close: price, session: session))
    }

    private mutating func fold(_ bar: Candle) {
        let period = start(of: bar.time, base)
        if let last = bars.last, start(of: last.time, base) == period {
            // The same period again (Yahoo's live point, or a quote): its
            // volume, if any, is the period's so far, not more on top.
            bars[bars.count - 1] = merged(last, bar, volume: max)
        } else if bars.last.map({ period > $0.time }) ?? true {
            var opened = bar
            opened.time = period
            bars.append(opened)
        }
    }

    private func merged(_ a: Candle, _ b: Candle, volume combine: (Double, Double) -> Double) -> Candle {
        let volume: Double? = switch (a.volume, b.volume) {
        case let (x?, y?): combine(x, y)
        case let (x, y): x ?? y
        }
        return Candle(time: a.time, open: a.open, high: max(a.high, b.high), low: min(a.low, b.low), close: b.close, session: a.session, volume: volume)
    }
}
