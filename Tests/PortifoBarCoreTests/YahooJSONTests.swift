import Foundation
import Testing
@testable import PortifoBarCore

// Trimmed from live responses, Nov 5, 2026.
private let spark = #"""
{"spark":{"result":[
 {"symbol":"AAPL","response":[{"meta":{"currency":"USD","symbol":"AAPL","fullExchangeName":"NasdaqGS",
  "exchangeTimezoneName":"America/New_York","regularMarketTime":1793891616,"hasPrePostMarketData":true,
  "regularMarketPrice":348.57,"chartPreviousClose":349.51,"previousClose":349.51,"priceHint":2,
  "shortName":"Apple Inc.","currentTradingPeriod":{"pre":{"start":1793869200,"end":1793889000},
  "regular":{"start":1793889000,"end":1793912400},"post":{"start":1793912400,"end":1793926800}}},
  "timestamp":[1793869200,1793869500,1793891616],
  "indicators":{"quote":[{"close":[350.99,null,348.57]}]}}]},
 {"symbol":"^GSPC","response":[{"meta":{"currency":"USD","symbol":"^GSPC","regularMarketTime":1793891610,
  "hasPrePostMarketData":false,"regularMarketPrice":7523.89,"chartPreviousClose":7688.62,"priceHint":2,
  "shortName":"S&P 500"},"timestamp":[1793889000],"indicators":{"quote":[{"close":[7600.1]}]}}]}
],"error":null}}
"""#

// One-minute bars: 4:00 pre-market, then 10:34, 10:35, 10:39, and a live
// point at 10:39:20 that belongs to the 10:39 bar.
private let chart1m = #"""
{"chart":{"result":[{"meta":{"symbol":"AAPL","exchangeTimezoneName":"America/New_York","priceHint":2,
 "regularMarketPrice":349.46,"regularMarketTime":1793893160,"previousClose":349.51,"hasPrePostMarketData":true,
 "currentTradingPeriod":{"pre":{"start":1793869200,"end":1793889000},
 "regular":{"start":1793889000,"end":1793912400},"post":{"start":1793912400,"end":1793926800}}},
 "timestamp":[1793869200,1793892840,1793892900,1793893140,1793893160],
 "indicators":{"quote":[{"open":[350.99,349.0,349.28,349.46,349.5],"high":[351.11,349.3,349.5,349.6,349.7],
  "low":[348.9,348.9,348.42,349.46,349.4],"close":[350.83,349.2,349.31,349.5,349.46]}]}}],"error":null}}
"""#

@Suite struct YahooJSONTests {
    @Test func sparkSnapshots() throws {
        let snapshots = try Spark.snapshots(from: Data(spark.utf8))
        #expect(snapshots.map(\.symbol) == ["AAPL", "^GSPC"])
        let aapl = snapshots[0]
        #expect(aapl.price == 348.57)
        #expect(aapl.previousClose == 349.51)
        #expect(aapl.name == "Apple Inc.")
        #expect(aapl.hasExtendedHours)
        #expect(aapl.day?.regularStart == Date(timeIntervalSince1970: 1_793_889_000))
        // The last bar with a close.
        #expect(aapl.lastBar == .init(price: 348.57, time: Date(timeIntervalSince1970: 1_793_891_616)))
        // previousClose missing: chartPreviousClose stands in.
        #expect(snapshots[1].previousClose == 7688.62)
        #expect(snapshots[1].day == nil)
    }

    @Test func symbolsAreEscaped() {
        #expect(YahooClient.encode("^GSPC") == "%5EGSPC")
        #expect(YahooClient.encode("EURUSD=X") == "EURUSD%3DX")
        #expect(YahooClient.encode("BRK-B") == "BRK-B")
        #expect(YahooClient.page(for: "SHOP.TO").absoluteString == "https://finance.yahoo.com/quote/SHOP.TO/")
    }

    @Test func dayInMinuteBars() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(chart1m.utf8)))
        let series = ChartJSON.series(chart)
        #expect(series.timeZone.identifier == "America/New_York")
        #expect(series.previousClose == 349.51)
        #expect(series.extendedHours)
        // The 10:39:20 live point folds into the 10:39 bar.
        #expect(series.bars.count == 4)
        #expect(series.bars.map(\.session) == [.pre, .regular, .regular, .regular])
        #expect(series.bars[3] == Candle(time: Date(timeIntervalSince1970: 1_793_893_140), open: 349.46, high: 349.7, low: 349.4, close: 349.46))
        // Its metadata makes the same snapshot spark would.
        #expect(ChartJSON.snapshot(chart)?.price == 349.46)
    }
}

@Suite struct VolumeTests {
    private func bar(_ minute: Double, _ volume: Double?, _ session: Session = .regular) -> Candle {
        Candle(time: Date(timeIntervalSince1970: 1_793_889_000 + minute * 60), open: 1, high: 1, low: 1, close: 1, session: session, volume: volume)
    }

    @Test func runningTotalsBecomeTheirMinute() {
        // Ten ordinary minutes (19.4M), then one holding the running total
        // through itself (20.2M: its own minute was 0.8M), then 1.1M.
        let minutes: [Double] = [9.2, 2, 1.2, 1, 1, 1, 1, 1, 1, 1]
        var bars = minutes.enumerated().map { bar(Double($0.offset), $0.element) }
        bars += [bar(10, 20.2), bar(11, 1.1)]
        let repaired = ChartJSON.repairingVolume(bars).map { $0.volume.map { ($0 * 10).rounded() / 10 } }
        #expect(repaired == minutes.map { $0 } + [0.8, 1.1])
    }

    @Test func extendedHoursZeroIsUnknown() {
        let repaired = ChartJSON.repairingVolume([bar(-30, 0, .pre), bar(0, 5), bar(400, 0, .post)])
        #expect(repaired.map(\.volume) == [nil, 5, nil])
    }

    @Test func candlesSumTheirMinutesAndALivePointDoesNot() {
        let open = Date(timeIntervalSince1970: 1_793_889_000)
        let day = TradingDay(preStart: open.addingTimeInterval(-19_800), regularStart: open, regularEnd: open.addingTimeInterval(23_400), postEnd: open.addingTimeInterval(37_800))
        // 9:30, 9:31, and Yahoo's live point inside 9:31 repeating its volume so far.
        let s = CandleSeries(symbol: "X", bars: [bar(0, 3), bar(1, 2), bar(1.5, 2.5)], day: day)
        #expect(s.bars.map(\.volume) == [3, 2.5])
        #expect(s.candles(.minutes(5)).first?.volume == 5.5)
        // Minutes with no volume reported leave a candle's unknown, not zero.
        let pre = CandleSeries(symbol: "X", bars: [bar(-2, nil, .pre), bar(-1, nil, .pre)], day: day)
        #expect(pre.candles(.minutes(5)).first?.volume == nil)
    }
}

@Suite struct CandleSeriesTests {
    let newYork = TimeZone(identifier: "America/New_York")!
    // Thursday's open, 9:30 New York.
    let open = Date(timeIntervalSince1970: 1_793_889_000)

    private func at(_ minutes: Double) -> Date { open.addingTimeInterval(minutes * 60) }

    private func bar(_ minutes: Double, _ o: Double, _ h: Double, _ l: Double, _ c: Double) -> Candle {
        Candle(time: at(minutes), open: o, high: h, low: l, close: c)
    }

    private var day: TradingDay {
        TradingDay(preStart: at(-330), regularStart: open, regularEnd: at(390), postEnd: at(630))
    }

    private func series(_ bars: [Candle]) -> CandleSeries {
        CandleSeries(symbol: "AAPL", bars: bars, timeZone: newYork, day: day, extendedHours: true)
    }

    private func quote(_ price: Double, _ time: Date) -> Quote {
        Quote(snapshot: Snapshot(symbol: "AAPL", price: price, time: time, previousClose: 349.51, day: day, hasExtendedHours: true))
    }

    @Test func periodsBuildFromMinutes() {
        // 10:34, 10:35, 10:36, 10:41.
        let s = series([bar(64, 10, 11, 9, 10.5), bar(65, 10.5, 12, 10, 11), bar(66, 11, 11.5, 8, 9), bar(71, 9, 9.5, 8.5, 9.2)])
        #expect(s.candles(.minutes(1)).count == 4)
        // 10:30–10:35 holds 10:34; 10:35–10:40 holds 10:35 and 10:36.
        #expect(s.candles(.minutes(5)) == [
            bar(60, 10, 11, 9, 10.5),
            bar(65, 10.5, 12, 8, 9),
            bar(70, 9, 9.5, 8.5, 9.2),
        ])
        // Hours run from the open: 10:30–11:30 holds them all.
        #expect(s.candles(.minutes(60)) == [bar(60, 10, 12, 8, 9.2)])
    }

    @Test func noCandleStraddlesTheOpen() {
        // 9:29 pre-market and 9:30 regular fall in different hours.
        let s = series([
            Candle(time: at(-1), open: 1, high: 1, low: 1, close: 1, session: .pre),
            bar(0, 2, 2, 2, 2),
        ])
        let hours = s.candles(.minutes(60))
        #expect(hours.map(\.time) == [at(-60), at(0)])
        #expect(hours.map(\.session) == [.pre, .regular])
    }

    @Test func quotesMoveTheLastBar() {
        var s = series([bar(64, 10, 11, 9, 10.5)])
        s.update(with: quote(8, at(64.5)))
        #expect(s.bars.last == bar(64, 10, 11, 8, 8))
        // Older than the bars: ignored.
        s.update(with: quote(400, at(64.2)))
        #expect(s.bars.last?.close == 8)
        // A new minute opens a new bar.
        s.update(with: quote(9, at(65.1)))
        #expect(s.bars.count == 2)
        #expect(s.bars.last == bar(65, 9, 9, 9, 9))
    }

    @Test func tradesOutsideTheDayStayOffTheChart() {
        // 7:59 PM, the day's last after-hours minute.
        var s = series([Candle(time: at(629), open: 10, high: 10, low: 10, close: 10, session: .post)])
        // 9:30 PM, overnight.
        var overnight = quote(9, at(390))
        overnight.apply(Tick(symbol: "AAPL", price: 11, time: at(720), marketHours: 4))
        #expect(overnight.latest.session == .overnight)
        s.update(with: overnight)
        #expect(s.bars.count == 1)
        #expect(s.bars.last?.close == 10)
    }

    @Test func otherSymbolsAreIgnored() {
        var s = CandleSeries(symbol: "MSFT", bars: [bar(0, 1, 1, 1, 1)], timeZone: newYork, day: day)
        s.update(with: quote(2, at(1)))
        #expect(s.bars.count == 1)
        #expect(s.bars.last?.close == 1)
    }
}
