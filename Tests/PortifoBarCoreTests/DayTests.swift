import Foundation
import Testing
@testable import PortifoBarCore

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
private let day: TimeInterval = 86_400

// Thursday Nov 5, 2026 in New York (EST): pre-market from 4:00, the session
// 9:30 to 16:00, after hours to 20:00. Friday is a day on.
private let thuPre = 1793869200.0, thuOpen = 1793889000.0, thuClose = 1793912400.0, thuEnd = 1793926800.0
private let friPre = thuPre + day, friOpen = thuOpen + day, friClose = thuClose + day, friEnd = thuEnd + day

// A two-day chart response as Yahoo gives the 1D query, its periods split
// into pre, regular and post. Each bar is (time, close); the regular
// price and its time are where the last session stands.
private func twoDays(_ bars: [(Double, Double)], price: Double, priceTime: Double, previousClose: Double) -> Data {
    let times = bars.map { String(Int($0.0)) }.joined(separator: ",")
    let closes = bars.map { String($0.1) }.joined(separator: ",")
    func window(_ a: Double, _ b: Double) -> String { #"[{"start":\#(Int(a)),"end":\#(Int(b))}]"# }
    return Data(#"""
    {"chart":{"result":[{"meta":{"symbol":"NVDA","exchangeTimezoneName":"America/New_York","priceHint":2,
     "instrumentType":"EQUITY","regularMarketPrice":\#(price),"regularMarketTime":\#(Int(priceTime)),
     "previousClose":\#(previousClose),"chartPreviousClose":200.13,"hasPrePostMarketData":true,"dataGranularity":"1m",
     "currentTradingPeriod":{"pre":{"start":\#(Int(friPre)),"end":\#(Int(friOpen))},
      "regular":{"start":\#(Int(friOpen)),"end":\#(Int(friClose))},"post":{"start":\#(Int(friClose)),"end":\#(Int(friEnd))}},
     "tradingPeriods":{"pre":[\#(window(thuPre, thuOpen)),\#(window(friPre, friOpen))],
      "regular":[\#(window(thuOpen, thuClose)),\#(window(friOpen, friClose))],
      "post":[\#(window(thuClose, thuEnd)),\#(window(friClose, friEnd))]}},
     "timestamp":[\#(times)],
     "indicators":{"quote":[{"open":[\#(closes)],"high":[\#(closes)],"low":[\#(closes)],"close":[\#(closes)]}]}}],"error":null}}
    """#.utf8)
}

// Thursday from its pre-market to its after hours.
private let thursday: [(Double, Double)] = [
    (thuPre, 190), (thuOpen, 195), (thuClose - 60, 181.5), (thuEnd - 60, 183),
]

private func series(_ data: Data) throws -> CandleSeries {
    ChartJSON.series(try #require(try ChartJSON.chart(from: data)), range: .day)
}

@Suite struct DayTests {
    @Test func beforeTheOpenTheDayBeforeRunsOnIntoTodaysPreMarket() throws {
        // Friday, 8:00: Thursday closed at 181.60, measured against
        // Wednesday's 200.13.
        let data = twoDays(thursday + [(friPre, 184), (friPre + 4 * 3600, 184.6)], price: 181.6, priceTime: thuClose + 1, previousClose: 200.13)
        let s = try series(data)
        #expect(s.bars.count == 6)
        #expect(s.bars.map(\.session) == [.pre, .regular, .regular, .post, .pre, .pre])
        #expect(s.days.count == 2)
        #expect(s.spansDays)
        // Thursday's points from Wednesday's close; Friday's pre-market from
        // Thursday's official close, which its last bar only approximates.
        #expect(s.reference(at: at(thuOpen)) == 200.13)
        #expect(s.reference(at: at(thuEnd - 60)) == 200.13)
        #expect(s.reference(at: at(friPre)) == 181.6)
        // The price above the chart is measured as before.
        #expect(ChartJSON.snapshot(try #require(try ChartJSON.chart(from: data)))?.previousClose == 200.13)
    }

    @Test func atTheOpenTheDayTurnsOver() throws {
        let data = twoDays(thursday + [(friPre, 184), (friOpen, 186)], price: 186, priceTime: friOpen + 30, previousClose: 181.6)
        let s = try series(data)
        #expect(s.bars.map(\.time) == [friPre, friOpen].map(at))
        #expect(s.days.count == 1)
        #expect(!s.spansDays)
        #expect(s.lastClose == nil)
        #expect(s.reference(at: at(friOpen)) == 181.6)
    }

    @Test func overnightTheDayStaysAndItsCloseMeasuresTheTrade() throws {
        // Thursday, 21:30: no bars past 20:00.
        let data = twoDays(thursday, price: 181.6, priceTime: thuClose + 1, previousClose: 200.13)
        let s = try series(data)
        #expect(s.bars.count == 4)
        #expect(!s.spansDays)
        #expect(s.lastClose == .init(close: 181.6, dayEnd: at(thuEnd)))
        #expect(s.reference(at: at(thuEnd - 60)) == 200.13)
        #expect(s.reference(at: at(thuEnd + 5400)) == 181.6)
    }

    @Test func aListingWithoutPreMarketTurnsOverAtTheOpen() throws {
        // Toronto at 8:00 Friday: Wednesday's and Thursday's sessions, no
        // pre-market. Thursday alone.
        let wedOpen = thuOpen - day, wedClose = thuClose - day
        let data = Data(#"""
        {"chart":{"result":[{"meta":{"symbol":"SHOP.TO","exchangeTimezoneName":"America/Toronto","priceHint":2,
         "instrumentType":"EQUITY","regularMarketPrice":201.23,"regularMarketTime":\#(Int(thuClose)),
         "previousClose":212.71,"chartPreviousClose":200.19,"hasPrePostMarketData":false,"dataGranularity":"1m",
         "tradingPeriods":[[{"start":\#(Int(wedOpen)),"end":\#(Int(wedClose))}],[{"start":\#(Int(thuOpen)),"end":\#(Int(thuClose))}]]},
         "timestamp":[\#(Int(wedClose - 60)),\#(Int(thuOpen)),\#(Int(thuClose - 60))],
         "indicators":{"quote":[{"open":[212.7,210,201.2],"high":[212.7,210,201.2],"low":[212.7,210,201.2],"close":[212.7,210,201.2]}]}}],"error":null}}
        """#.utf8)
        let s = try series(data)
        #expect(s.bars.map(\.time) == [thuOpen, thuClose - 60].map(at))
        #expect(s.reference(at: at(thuOpen)) == 212.71)
    }

    @Test func aMarketThatNeverClosesShowsTheLast24Hours() throws {
        // Every hour, unbroken, from Thursday 00:00 UTC to Friday 06:00: 30
        // hours.
        let midnight = 1793836800.0
        let times = (0...30).map { midnight + Double($0) * 3600 }
        let closes = times.indices.map { 75_000 + Double($0) * 100 }
        let data = Data(#"""
        {"chart":{"result":[{"meta":{"symbol":"BTC-USD","exchangeTimezoneName":"UTC","priceHint":2,
         "instrumentType":"CRYPTOCURRENCY","regularMarketPrice":76000,"regularMarketTime":\#(Int(times.last!)),
         "previousClose":75800,"chartPreviousClose":74900,"hasPrePostMarketData":false,"dataGranularity":"1m",
         "tradingPeriods":[[{"start":\#(Int(midnight)),"end":\#(Int(midnight + day - 1))}],[{"start":\#(Int(midnight + day)),"end":\#(Int(midnight + 2 * day - 1))}]]},
         "timestamp":[\#(times.map { String(Int($0)) }.joined(separator: ","))],
         "indicators":{"quote":[{"open":\#(closes),"high":\#(closes),"low":\#(closes),"close":\#(closes)}]}}],"error":null}}
        """#.utf8)
        let s = try series(data)
        #expect(s.isLast24Hours)
        // From Thursday 06:00, and measured against the price then: the
        // 05:00 bar's close.
        #expect(s.bars.first?.time == at(midnight + 6 * 3600))
        #expect(s.bars.count == 25)
        #expect(s.previousClose == 75_500)
        #expect(s.lastClose == nil)
        #expect(s.spansDays)
    }
}
