import Foundation
import Testing
@testable import PortifoBarCore

private let newYork = TimeZone(identifier: "America/New_York")!
private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

// A week of 15-minute bars as Yahoo gives them for the regular session
// (trimmed): Wednesday Oct 28, Friday Oct 30 and Thursday Nov 5, 2026, the
// last ending on its 16:00 closing print. New York left daylight time on
// Nov 1, so Friday opens at 13:30 UTC and Thursday at 14:30.
private let week = #"""
{"chart":{"result":[{"meta":{"symbol":"NVDA","exchangeTimezoneName":"America/New_York","priceHint":2,
 "regularMarketPrice":181.6,"regularMarketTime":1793912400,"previousClose":200.13,"chartPreviousClose":217.94,
 "hasPrePostMarketData":true,"dataGranularity":"15m",
 "currentTradingPeriod":{"pre":{"start":1793869200,"end":1793889000},
  "regular":{"start":1793889000,"end":1793912400},"post":{"start":1793912400,"end":1793926800}},
 "tradingPeriods":[[{"start":1793194200,"end":1793217600}],[{"start":1793367000,"end":1793390400}],[{"start":1793889000,"end":1793912400}]]},
 "timestamp":[1793216700,1793367000,1793367900,1793911500,1793912400],
 "indicators":{"quote":[{"open":[100,103,104,182,181.6],"high":[100,103,104,182,181.6],
  "low":[100,103,104,181,181.6],"close":[100,103,104,181.5,181.6],"volume":[5,10,20,30,0]}]}}],"error":null}}
"""#

// The same days as the day's chart sees them, split into pre-market,
// regular and after hours, as Yahoo marks them out where a listing trades
// extended hours.
private let split = #"""
{"chart":{"result":[{"meta":{"symbol":"NVDA","exchangeTimezoneName":"America/New_York","priceHint":2,
 "regularMarketPrice":181.6,"regularMarketTime":1793912400,"previousClose":200.13,
 "hasPrePostMarketData":true,"dataGranularity":"15m",
 "tradingPeriods":{
  "pre":[[{"start":1793174400,"end":1793194200}],[{"start":1793347200,"end":1793367000}],[{"start":1793869200,"end":1793889000}]],
  "regular":[[{"start":1793194200,"end":1793217600}],[{"start":1793367000,"end":1793390400}],[{"start":1793889000,"end":1793912400}]],
  "post":[[{"start":1793217600,"end":1793232000}],[{"start":1793390400,"end":1793404800}],[{"start":1793912400,"end":1793926800}]]}},
 "timestamp":[1793217600,1793347200,1793367000,1793925900],
 "indicators":{"quote":[{"open":[101,102,103,183],"high":[101,102,103,183],"low":[101,102,103,183],
  "close":[101,102,103,183],"volume":[0,0,10,0]}]}}],"error":null}}
"""#

// Weekly bars, and Yahoo's live point after them: today's daily bar,
// which this week's bar already counts.
private let weekly = #"""
{"chart":{"result":[{"meta":{"symbol":"NVDA","exchangeTimezoneName":"America/New_York","priceHint":2,
 "regularMarketPrice":181.6,"regularMarketTime":1793912400,"chartPreviousClose":139.91,"dataGranularity":"1wk"},
 "timestamp":[1792987200,1793595600,1793912400],
 "indicators":{"quote":[{"open":[213.11,207.53,196.07],"high":[220,209,197],"low":[204,190,180.5],
  "close":[204.64,181.6,181.6],"volume":[514613700,663407800,301617834]}]}}],"error":null}}
"""#

// A Toronto listing's afternoon: no extended hours, so Yahoo lists each
// day's regular session alone, and ends on the 16:00 closing print.
private let toronto = #"""
{"chart":{"result":[{"meta":{"symbol":"SHOP.TO","exchangeTimezoneName":"America/Toronto","priceHint":2,
 "regularMarketPrice":201.23,"regularMarketTime":1793912400,"chartPreviousClose":233.44,
 "hasPrePostMarketData":false,"dataGranularity":"15m",
 "tradingPeriods":[[{"start":1793889000,"end":1793912400}]]},
 "timestamp":[1793910600,1793911500,1793912400],
 "indicators":{"quote":[{"open":[201,202,201.5],"high":[202,203,201.5],"low":[200,201,201.23],
  "close":[202,201.5,201.23],"volume":[100,200,0]}]}}],"error":null}}
"""#

@Suite struct RangeTests {
    @Test func weekKeepsSevenCalendarDays() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(week.utf8)))
        let series = ChartJSON.series(chart, range: .week)
        #expect(series.base == .minutes(15))
        // Only the day's chart runs into extended hours.
        #expect(!series.extendedHours)
        // Wednesday is more than a week before Thursday: dropped, and its
        // close the week is measured against. Thursday's closing print
        // closes its 15:45 bar.
        #expect(series.bars.map(\.time) == [1793367000, 1793367900, 1793911500].map(at))
        #expect(series.bars.last?.close == 181.6)
        #expect(series.bars.last?.volume == 30)
        #expect(series.previousClose == 100)
        #expect(series.days.count == 2)
        #expect(series.bars.allSatisfy { $0.session == .regular })
    }

    @Test func barsCountFromEachDaysOwnOpen() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(week.utf8)))
        let series = ChartJSON.series(chart, range: .week)
        // Two hours from 9:30 each day, daylight time or not: Friday's 9:30
        // EDT and Thursday's 15:30 EST.
        let candles = series.candles(.minutes(120))
        #expect(candles.map(\.time) == [1793367000, 1793910600].map(at))
        #expect(candles[0].close == 104)
        #expect(candles[0].volume == 30)
    }

    @Test func splitTradingPeriodsMarkEachDaysSessions() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(split.utf8)))
        // A range that keeps every day: the day's chart keeps only its last
        // (see DayTests).
        let series = ChartJSON.series(chart, range: .month)
        #expect(series.days.count == 3)
        #expect(series.days[1].preStart == at(1793347200))
        #expect(series.days[1].postEnd == at(1793404800))
        // Wednesday's 16:00 and Thursday's 19:45 after hours, Friday's 4:00 pre-market.
        #expect(series.bars.map(\.session) == [.post, .pre, .regular, .post])
        // Zero outside the regular session means unknown.
        #expect(series.bars.map(\.volume) == [nil, nil, 10, nil])
    }

    @Test func liveWeeklyPointFoldsIntoItsWeek() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(weekly.utf8)))
        var series = ChartJSON.series(chart, range: .twoYears)
        #expect(series.base == .week)
        #expect(series.bars.count == 2)
        let thisWeek = try #require(series.bars.last)
        #expect(thisWeek.open == 207.53)
        #expect(thisWeek.low == 180.5)
        // The week's volume already counts today's.
        #expect(thisWeek.volume == 663_407_800)
        #expect(series.previousClose == 139.91)
        // October and November.
        #expect(series.candles(.month).count == 2)

        // A regular trade (Friday, 10:00) moves this week's candle; an
        // after-hours one doesn't.
        var quote = Quote(snapshot: Snapshot(symbol: "NVDA", price: 185, time: at(1793912400 + 18 * 3600), previousClose: 181.6))
        series.update(with: quote)
        #expect(series.bars.count == 2)
        #expect(series.bars.last?.close == 185)
        quote.extended = ExtendedTrade(session: .post, price: 190, time: at(1793912400 + 86_400 + 600))
        series.update(with: quote)
        #expect(series.bars.last?.close == 185)
    }

    @Test func aDailyBarIsTheExchangesDay() {
        let open = Date(timeIntervalSince1970: 1_793_889_000)
        let bar = Candle(time: open, open: 1, high: 1, low: 1, close: 1)
        let series = CandleSeries(symbol: "X", bars: [bar], timeZone: newYork, range: .month, base: .day)
        // From midnight on the exchange's calendar, not Yahoo's 9:30 stamp.
        #expect(series.bars.first?.time == newYork.startOfDay(open))
    }

    @Test func longerRangesFollowTheRegularSessionAlone() {
        // Thursday's last 15 minutes, on a week's line.
        let day = TradingDay(preStart: at(1793869200), regularStart: at(1793889000), regularEnd: at(1793912400), postEnd: at(1793926800))
        let bar = Candle(time: at(1793911500), open: 200, high: 200, low: 200, close: 200)
        var series = CandleSeries(symbol: "NVDA", bars: [bar], timeZone: newYork, day: day, range: .week, base: .minutes(15))
        // The closing print at 16:00 closes the 15:45 bar.
        var quote = Quote(snapshot: Snapshot(symbol: "NVDA", price: 201, time: day.regularEnd, previousClose: 205, day: day, hasExtendedHours: true))
        series.update(with: quote)
        #expect(series.bars.count == 1)
        #expect(series.bars.last?.close == 201)
        // After hours, which the line doesn't run into, leaves it be.
        quote.apply(Tick(symbol: "NVDA", price: 210, time: at(1793912400 + 1800), marketHours: 2))
        #expect(quote.latest.session == .post)
        series.update(with: quote)
        #expect(series.bars.count == 1)
        #expect(series.bars.last?.close == 201)
    }

    @Test func anHourEndsAtTheClose() {
        let day = TradingDay(preStart: at(1793869200), regularStart: at(1793889000), regularEnd: at(1793912400), postEnd: at(1793926800))
        let lastHour = at(1793912400 - 1800) // 15:30
        let bar = Candle(time: lastHour, open: 1, high: 1, low: 1, close: 1)
        // A month's hours stop at 16:00; the day's run on into after hours.
        let month = CandleSeries(symbol: "NVDA", bars: [bar], timeZone: newYork, day: day, range: .month, base: .minutes(60))
        #expect(month.end(of: lastHour, .minutes(60)) == day.regularEnd)
        let today = CandleSeries(symbol: "NVDA", bars: [bar], timeZone: newYork, day: day, extendedHours: true)
        #expect(today.end(of: lastHour, .minutes(60)) == at(1793912400 + 1800))
    }

    @Test func theDaysLineEndsOvernightOnTheLatestTrade() {
        let day = TradingDay(preStart: at(1793869200), regularStart: at(1793889000), regularEnd: at(1793912400), postEnd: at(1793926800))
        // 19:50 to 19:59, minute by minute: two five-minute points.
        let minutes = (0..<10).map { m in
            Candle(time: at(1793926800 - 600 + Double(m) * 60), open: 100, high: 100, low: 100, close: 100 + Double(m), session: .post)
        }
        let series = CandleSeries(symbol: "NVDA", bars: minutes, timeZone: newYork, day: day, extendedHours: true)
        #expect(series.lineSpan == .minutes(5))
        #expect(series.line(through: nil).map(\.close) == [104, 109])

        // 21:30, overnight: one point past the after hours, at the trade's own time.
        var quote = Quote(snapshot: Snapshot(symbol: "NVDA", price: 99, time: day.regularEnd, previousClose: 98, day: day, hasExtendedHours: true))
        quote.apply(Tick(symbol: "NVDA", price: 112, time: at(1793926800 + 5400), marketHours: 4))
        let line = series.line(through: quote)
        #expect(line.count == 3)
        #expect(line.last == Candle(time: at(1793926800 + 5400), open: 112, high: 112, low: 112, close: 112, session: .overnight))
        // Longer ranges draw their bars alone.
        let week = CandleSeries(symbol: "NVDA", bars: minutes, timeZone: newYork, day: day, range: .week, base: .minutes(15))
        #expect(week.line(through: quote).count == 1)
    }

    @Test func rangesAskForPortifosBars() {
        let now = at(1_793_935_000)
        #expect(ChartRange.day.query(at: now) == "range=2d&interval=1m&includePrePost=true")
        #expect(ChartRange.week.query(at: now) == "range=7d&interval=15m")
        #expect(ChartRange.month.query(at: now) == "range=1mo&interval=60m")
        #expect(ChartRange.year.query(at: now) == "range=1y&interval=1d")
        #expect(ChartRange.fiveYears.query(at: now) == "range=5y&interval=1wk")
        #expect(ChartRange.allCases.filter(\.includesExtendedHours) == [.day])
    }

    @Test func closingPrintJoinsTheLastCandle() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(toronto.utf8)))
        let series = ChartJSON.series(chart, range: .week)
        #expect(series.days.first?.preStart == series.days.first?.regularStart)
        // 15:30 and 15:45; the 16:00 print closes the 15:45 bar.
        #expect(series.bars.map(\.time) == [1793910600, 1793911500].map(at))
        #expect(series.bars.last?.close == 201.23)
        #expect(series.bars.allSatisfy { $0.session == .regular })
    }

    @Test func allTimeAsksForCalendarMonths() {
        let query = ChartRange.all.query(at: at(1_793_935_000))
        #expect(query == "period1=-2208988800&period2=1793935000&interval=1mo")
    }
}

private extension TimeZone {
    func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self
        return calendar.startOfDay(for: date)
    }
}
