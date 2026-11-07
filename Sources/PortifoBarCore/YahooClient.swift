import Foundation

public enum YahooError: Error, Equatable, Sendable {
    case rateLimited
    case http(Int)
    case invalidResponse
}

public struct SearchResult: Sendable, Equatable {
    public var symbol: String
    public var name: String?
    public var exchange: String?
    public var type: String?
}

// Yahoo Finance's public REST endpoints. Unlike /v7/finance/quote, which
// Portifo reaches through yahoo-finance2's cookie-and-crumb dance, spark and
// search answer a plain GET.
public struct YahooClient: Sendable {
    // Yahoo turns away clients that don't look like a browser.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // Spark's own cap on symbols per request.
    static let sparkBatch = 20

    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    // A snapshot of each symbol Yahoo knows; the rest are left out. One
    // request per 20 symbols. Only with `bars` does a snapshot carry the
    // latest pre-market or after-hours trade, at three or four times the
    // size, so ask for them only outside the regular session.
    public func snapshots(for symbols: [String], bars: Bool = true) async throws -> [Snapshot] {
        var result: [Snapshot] = []
        for start in stride(from: 0, to: symbols.count, by: Self.sparkBatch) {
            let batch = Array(symbols[start..<min(start + Self.sparkBatch, symbols.count)])
            result += try await spark(batch, bars: bars)
        }
        return result
    }

    // The chart endpoint's metadata for several symbols at once. With
    // `bars`, the day's 5-minute bars come too, extended hours included;
    // without, a single daily bar, which says nothing the metadata doesn't.
    private func spark(_ symbols: [String], bars: Bool) async throws -> [Snapshot] {
        let list = symbols.map(Self.encode).joined(separator: ",")
        let shape = bars ? "interval=5m&includePrePost=true" : "interval=1d"
        // Yahoo's edge caches spark for five minutes (max-age=300): the same
        // URL twice gets the same prices back. A URL of its own each time
        // reaches the origin, a second or two behind the trade.
        let buster = Int(Date.now.timeIntervalSince1970 * 1000)
        let url = URL(string: "https://query1.finance.yahoo.com/v7/finance/spark?symbols=\(list)&range=1d&\(shape)&_=\(buster)")!
        let (data, status) = try await get(url)
        // None of the symbols known.
        if status == 404 { return [] }
        guard status == 200 else { throw YahooError.http(status) }
        return try Spark.snapshots(from: data)
    }

    // The symbol's chart over `range` from the chart endpoint (cached at
    // Yahoo's edge for ten seconds, so it gets a URL of its own too): the day
    // in one-minute bars, pre-market and after hours included, or a longer
    // range in Yahoo's bars for it. The day's metadata also makes a snapshot,
    // as fresh a price as a spark poll's; a longer range's can't, as it
    // gives no previous close but the one before the range.
    public func chart(for symbol: String, range: ChartRange) async throws -> (series: CandleSeries, snapshot: Snapshot?) {
        let now = Date.now
        let buster = Int(now.timeIntervalSince1970 * 1000)
        let query = "\(range.query(at: now))&_=\(buster)"
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(Self.encode(symbol))?\(query)")!
        let (data, status) = try await get(url)
        guard status == 200 else { throw YahooError.http(status) }
        guard let chart = try ChartJSON.chart(from: data) else { throw YahooError.invalidResponse }
        return (ChartJSON.series(chart, range: range), range == .day ? ChartJSON.snapshot(chart) : nil)
    }

    // The symbol's daily closes from `start` to now, regular session only,
    // oldest first: what the moving average is taken over. While a session
    // trades, its close is the latest price.
    public func dailyCloses(for symbol: String, from start: Date) async throws -> [DailyClose] {
        let now = Date.now
        let query = "period1=\(Int(start.timeIntervalSince1970))&period2=\(Int(now.timeIntervalSince1970))&interval=1d&_=\(Int(now.timeIntervalSince1970 * 1000))"
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(Self.encode(symbol))?\(query)")!
        let (data, status) = try await get(url)
        guard status == 200 else { throw YahooError.http(status) }
        guard let chart = try ChartJSON.chart(from: data) else { throw YahooError.invalidResponse }
        return ChartJSON.dailyCloses(chart)
    }

    public func search(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "6"),
            URLQueryItem(name: "newsCount", value: "0"),
        ]
        let (data, status) = try await get(components.url!)
        guard status == 200 else { throw YahooError.http(status) }
        let body = try JSONDecoder().decode(SearchBody.self, from: data)
        return (body.quotes ?? [])
            .filter { $0.isYahooFinance != false && !($0.symbol ?? "").isEmpty }
            .map {
                SearchResult(
                    symbol: $0.symbol!,
                    name: $0.shortname ?? $0.longname,
                    exchange: $0.exchDisp ?? $0.exchange,
                    type: $0.typeDisp ?? $0.quoteType
                )
            }
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YahooError.invalidResponse }
        if http.statusCode == 429 { throw YahooError.rateLimited }
        return (data, http.statusCode)
    }

    // The symbol's page on finance.yahoo.com.
    public static func page(for symbol: String) -> URL {
        URL(string: "https://finance.yahoo.com/quote/\(encode(symbol))/")!
    }

    // Symbols carry ^ (indices) and = (currencies, futures), which a query
    // string must escape.
    static func encode(_ symbol: String) -> String {
        symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? symbol
    }
}

// The chart endpoint's JSON, which spark wraps one level deeper.
enum ChartJSON {
    static func snapshot(_ chart: Chart) -> Snapshot? {
        let m = chart.meta
        guard let price = m.regularMarketPrice, price > 0, let time = m.regularMarketTime else { return nil }
        let closes = chart.indicators?.quote?.first?.close ?? []
        let lastBar = Array(zip(chart.timestamp ?? [], closes))
            .last { $0.1 != nil }
            .map { Snapshot.Bar(price: $0.1!, time: date($0.0)) }
        return Snapshot(
            symbol: m.symbol,
            name: m.shortName ?? m.longName,
            currency: m.currency,
            exchange: m.fullExchangeName ?? m.exchangeName,
            decimals: m.priceHint ?? 2,
            price: price,
            time: date(time),
            previousClose: m.previousClose ?? m.chartPreviousClose,
            day: m.day,
            hasExtendedHours: m.hasPrePostMarketData ?? false,
            lastBar: lastBar
        )
    }

    struct Chart: Decodable {
        let meta: Meta
        let timestamp: [Double]?
        let indicators: Indicators?
    }

    struct Indicators: Decodable {
        let quote: [Bars]?
        struct Bars: Decodable {
            let open: [Double?]?
            let high: [Double?]?
            let low: [Double?]?
            let close: [Double?]?
            let volume: [Double?]?
        }
    }

    struct Meta: Decodable {
        let symbol: String
        let currency: String?
        let shortName: String?
        let longName: String?
        let fullExchangeName: String?
        let exchangeName: String?
        let exchangeTimezoneName: String?
        let regularMarketPrice: Double?
        let regularMarketTime: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let priceHint: Int?
        let hasPrePostMarketData: Bool?
        let currentTradingPeriod: Periods?
        let dataGranularity: String?
        let tradingPeriods: TradingPeriods?

        struct Periods: Decodable {
            let pre: Window?
            let regular: Window?
            let post: Window?
        }

        struct Window: Decodable {
            let start: Double
            let end: Double
        }

        // Every day an intraday chart covers, one entry a day: split into
        // pre, regular and post where the listing trades extended hours,
        // and the regular session's alone otherwise (crypto, Toronto). A
        // session with a lunch break comes in pieces.
        struct TradingPeriods: Decodable {
            let days: [TradingDay]

            private struct Split: Decodable {
                let pre: [[Window]]?
                let regular: [[Window]]
                let post: [[Window]]?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                func span(_ pieces: [Window]?) -> (Date, Date)? {
                    guard let first = pieces?.first, let last = pieces?.last else { return nil }
                    return (date(first.start), date(last.end))
                }
                if let split = try? container.decode(Split.self) {
                    days = split.regular.indices.compactMap { i in
                        guard let regular = span(split.regular[i]) else { return nil }
                        let pre = span(split.pre?[safe: i])
                        let post = span(split.post?[safe: i])
                        return TradingDay(preStart: pre?.0 ?? regular.0, regularStart: regular.0, regularEnd: regular.1, postEnd: post?.1 ?? regular.1)
                    }
                } else if let list = try? container.decode([[Window]].self) {
                    days = list.compactMap { span($0) }.map {
                        TradingDay(preStart: $0.0, regularStart: $0.0, regularEnd: $0.1, postEnd: $0.1)
                    }
                } else {
                    days = []
                }
            }
        }

        var day: TradingDay? {
            guard let p = currentTradingPeriod, let regular = p.regular else { return nil }
            return TradingDay(
                preStart: date(p.pre?.start ?? regular.start),
                regularStart: date(regular.start),
                regularEnd: date(regular.end),
                postEnd: date(p.post?.end ?? regular.end)
            )
        }
    }

    private struct Body: Decodable {
        let chart: Result?
        struct Result: Decodable {
            let result: [Chart]?
        }
    }

    static func date(_ epochSeconds: Double) -> Date {
        Date(timeIntervalSince1970: epochSeconds)
    }

    // Yahoo's one-minute volume for the current day is unreliable in two ways:
    // pre-market and after-hours bars always say 0, which means unknown;
    // and now and then a regular-session bar holds the day's running total
    // instead of its own minute (131M for a minute of a 163M day). A bar
    // holding at least everything traded before it in the session, once the
    // session is under way, is one of those: its own minute is the
    // difference. Repaired, the minutes add up to Yahoo's day total.
    static func repairingVolume(_ bars: [Candle]) -> [Candle] {
        var traded = 0.0
        var counted = 0
        return bars.map { bar in
            var bar = bar
            guard bar.session == .regular else {
                if bar.volume == 0 { bar.volume = nil }
                return bar
            }
            guard var volume = bar.volume else { return bar }
            if counted >= 10, traded > 0, volume >= traded {
                volume -= traded
            }
            bar.volume = volume
            traded += volume
            counted += 1
            return bar
        }
    }

    // Daily bars' closes, one per session. Yahoo leaves a day with no
    // close as null (BTC-USD, now and then), and can end on a live point
    // beside today's bar, which is that bar again: a session keeps its first
    // time and its last close.
    static func dailyCloses(_ chart: Chart) -> [DailyClose] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chart.meta.exchangeTimezoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        let closes = chart.indicators?.quote?.first?.close ?? []
        var out: [DailyClose] = []
        for (i, t) in (chart.timestamp ?? []).enumerated() {
            guard let close = closes[safe: i] ?? nil, close > 0 else { continue }
            let time = date(t)
            if let last = out.last, calendar.isDate(last.time, inSameDayAs: time) {
                out[out.count - 1].close = close
            } else if out.last.map({ time > $0.time }) ?? true {
                out.append(DailyClose(time: time, close: close))
            }
        }
        return out
    }

    static func chart(from data: Data) throws -> Chart? {
        try JSONDecoder().decode(Body.self, from: data).chart?.result?.first
    }

    static func series(_ chart: Chart, range: ChartRange = .day) -> CandleSeries {
        let m = chart.meta
        let bars = chart.indicators?.quote?.first
        let times = chart.timestamp ?? []
        let day = m.day
        let base = m.dataGranularity.flatMap(CandleSpan.init(granularity:)) ?? range.base
        // Sessions are an intraday matter: a daily bar is the regular session's.
        var days: [TradingDay] = []
        if base.isIntraday {
            days = m.tradingPeriods?.days ?? []
            if days.isEmpty, let day { days = [day] }
        }
        var candles: [Candle] = []
        for (i, t) in times.enumerated() {
            // A bar with any of its four missing is a gap in trading, not a candle.
            guard
                let open = bars?.open?[safe: i] ?? nil,
                let high = bars?.high?[safe: i] ?? nil,
                let low = bars?.low?[safe: i] ?? nil,
                let close = bars?.close?[safe: i] ?? nil
            else { continue }
            let time = date(t)
            var session = Session.regular
            if let day = days.last(where: { $0.preStart <= time }), time < day.postEnd {
                session = time < day.regularStart ? .pre : time < day.regularEnd ? .regular : .post
            }
            let volume = bars?.volume?[safe: i] ?? nil
            candles.append(Candle(time: time, open: open, high: high, low: low, close: close, session: session, volume: volume))
        }
        let timeZone = m.exchangeTimezoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        var previousClose = range == .day ? m.previousClose ?? m.chartPreviousClose : m.chartPreviousClose
        var kept = days
        var lastClose: CandleSeries.LastClose?
        // A market that never pauses for a night (crypto, currencies through
        // the week, futures, whose daily halt is an hour) has no trading day
        // to keep: its latest unbroken run of bars is longer than a day.
        var last24Hours = false
        if range == .day, var start = candles.indices.last {
            while start > 0, candles[start].time.timeIntervalSince(candles[start - 1].time) <= 2 * 3600 { start -= 1 }
            last24Hours = candles[candles.count - 1].time.timeIntervalSince(candles[start].time) > 86_400
        }
        if range == .day, let last = candles.last {
            if last24Hours {
                // The last 24 hours instead, measured against the price at
                // their start. Portifo's 1D does the same.
                let cutoff = last.time.addingTimeInterval(-86_400)
                previousClose = candles.last { $0.time < cutoff }?.close ?? previousClose
                candles.removeAll { $0.time < cutoff }
                kept.removeAll { $0.postEnd <= cutoff }
            } else if let d = days.lastIndex(where: { $0.preStart <= last.time }) {
                // The latest bar's trading day, and before its regular
                // session opens, the whole day before it too. A listing with
                // no pre-market (Toronto, an index) turns over at the open.
                let from = last.time < days[d].regularStart && d > 0 ? days[d - 1].preStart : days[d].preStart
                candles.removeAll { $0.time < from }
                kept.removeAll { $0.postEnd <= from }
            }
            // Before the open and overnight, the regular price is the last
            // session's official close, which the bars only approximate
            // (QQQ's 4 PM bar: 646.49, its close 647.05).
            if !last24Hours, let price = m.regularMarketPrice, let time = m.regularMarketTime.map(date),
               let session = days.last(where: { $0.regularStart <= time }), time >= session.regularEnd {
                lastClose = .init(close: price, dayEnd: session.postEnd)
            }
        }
        if range == .week, let last = candles.last {
            // Seven calendar days, the last of them today's, and measured
            // against the close before them: a regular session's, if any.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: last.time)) ?? last.time
            let before = candles.filter { $0.time < cutoff }
            previousClose = (before.last { $0.session == .regular } ?? before.last)?.close ?? previousClose
            candles.removeAll { $0.time < cutoff }
            kept.removeAll { $0.postEnd <= cutoff }
        }
        return CandleSeries(
            symbol: m.symbol,
            // Only the day's one-minute bars have been seen to need it.
            bars: range == .day ? repairingVolume(candles) : candles.map { bar in
                var bar = bar
                if bar.session != .regular, bar.volume == 0 { bar.volume = nil }
                return bar
            },
            previousClose: previousClose,
            decimals: m.priceHint ?? 2,
            timeZone: timeZone,
            asOf: times.last.map(date),
            day: day,
            extendedHours: (m.hasPrePostMarketData ?? false) && range.includesExtendedHours,
            range: range,
            base: base,
            days: kept,
            lastClose: lastClose,
            isLast24Hours: last24Hours
        )
    }
}

enum Spark {
    static func snapshots(from data: Data) throws -> [Snapshot] {
        let body = try JSONDecoder().decode(Body.self, from: data)
        return (body.spark?.result ?? []).compactMap { $0.response?.first.flatMap(ChartJSON.snapshot) }
    }

    private struct Body: Decodable {
        let spark: Result?
        struct Result: Decodable {
            let result: [Item]?
        }
        struct Item: Decodable {
            let symbol: String
            let response: [ChartJSON.Chart]?
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct SearchBody: Decodable {
    let quotes: [Hit]?
    struct Hit: Decodable {
        let symbol: String?
        let shortname: String?
        let longname: String?
        let exchDisp: String?
        let exchange: String?
        let typeDisp: String?
        let quoteType: String?
        let isYahooFinance: Bool?
    }
}
