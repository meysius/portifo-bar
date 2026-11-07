import Foundation
import Testing
@testable import PortifoBarCore

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

// Four sessions' daily bars, stamped at the 9:30 open as Yahoo stamps them,
// day 0 to day 3.
private let open: TimeInterval = 9.5 * hour
private let closes = [10.0, 20, 30, 40].enumerated().map { DailyClose(time: at(Double($0) * day + open), close: $1) }

// Daily bars as Yahoo gave them on Nov 5, 2026 (after the close): stamped
// at New York's 9:30 open, a day with a null close, and a live point beside
// today's bar, which is that bar again.
private let daily = #"""
{"chart":{"result":[{"meta":{"symbol":"AAPL","exchangeTimezoneName":"America/New_York","dataGranularity":"1d"},
 "timestamp":[1793629800,1793716200,1793802600,1793889000,1793912400],
 "indicators":{"quote":[{"close":[338.32,null,349.51,344.0,344.17]}]}}],"error":null}}
"""#

@Suite struct MovingAverageTests {
    @Test func dailyPointsTakeTheirOwnDaysAverage() {
        let times = closes.map(\.time)
        // Two sessions to a window: none until the second.
        #expect(MovingAverage.values(at: times, closes: closes, window: 2) == [nil, 15, 25, 35])
    }

    @Test func intradayPointsHoldTheirSessionsAverage() {
        // Day 2's pre-market at 4:00, its session at 9:30 and 12:00, and its
        // after hours at 16:00.
        let times = [4 * hour, open, 12 * hour, 16 * hour].map { at(2 * day + $0) }
        let values = MovingAverage.values(at: times, closes: Array(closes.prefix(3)), window: 2)
        // The pre-market takes the average to the day before; the session
        // and after its own, which counts its close.
        #expect(values == [15, 25, 25, 25])
    }

    @Test func theLastPointCountsEveryClose() {
        // A weekly bar from day 0 spans the week: its last session's average.
        #expect(MovingAverage.values(at: [at(0)], closes: closes, window: 2) == [35])
    }

    @Test func aWindowSlidesOffItsOldestClose() {
        let times = closes.map(\.time)
        #expect(MovingAverage.values(at: times, closes: closes, window: 3) == [nil, nil, 20, 30])
    }

    @Test func closesReachBackAFullWindow() {
        let start = at(1_000 * day)
        // 200 sessions take 280 calendar days; three weeks more for holidays.
        #expect(MovingAverage.closesStart(for: start) == at(699 * day))
    }

    @Test func dailyClosesSkipGapsAndFoldTodaysLivePoint() throws {
        let chart = try #require(try ChartJSON.chart(from: Data(daily.utf8)))
        let parsed = ChartJSON.dailyCloses(chart)
        #expect(parsed.map(\.time) == [1793629800, 1793802600, 1793889000].map(at))
        #expect(parsed.map(\.close) == [338.32, 349.51, 344.17])
    }
}

@Suite struct SMABandsTests {
    @Test func drawsTheAverageAndTheBandsThePriceCrosses() throws {
        // From 3% below the average to 12% above it.
        let bands = try #require(SMABands(prices: [97, 112, 105], average: [100, 100, 100]))
        #expect(bands.drawn.map(\.label) == ["+10%", "+5%", "SMA"])
        #expect(bands.crosses(SMABands.levels[3]))
        #expect(bands.stayed == nil)
        #expect(abs(try #require(bands.gap(at: 1, price: 112)) - 12) < 1e-9)
    }

    @Test func theAverageIsDrawnEvenWhenThePriceStaysClearOfIt() throws {
        let bands = try #require(SMABands(prices: [106, 108], average: [100, 100]))
        #expect(bands.drawn.map(\.label) == ["SMA"])
        #expect(!bands.crosses(SMABands.levels[3]))
        #expect(bands.stayed == "Stayed between +10% and +5%")
    }

    @Test func namesTheAverageWhenThePriceStaysNextToIt() throws {
        let below = try #require(SMABands(prices: [97, 98], average: [100, 100]))
        #expect(below.stayed == "Stayed between the SMA and \u{2212}5%")
        let farAbove = try #require(SMABands(prices: [120, 125], average: [100, 100]))
        #expect(farAbove.stayed == "Stayed above +15%")
    }

    @Test func pointsWithoutAnAverageAreLeftOut() throws {
        #expect(SMABands(prices: [100, 101], average: [nil, nil]) == nil)
        let bands = try #require(SMABands(prices: [150, 101], average: [nil, 100]))
        #expect(bands.low == bands.high)
        #expect(bands.gap(at: 0, price: 150) == nil)
    }
}
