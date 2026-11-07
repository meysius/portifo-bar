import Foundation
import Testing
@testable import PortifoBarCore

// Nasdaq's Thursday, Nov 5, 2026, as Yahoo gives it: pre-market from 4:00,
// the regular session 9:30–16:00, after hours until 20:00 (New York).
private let thursday = TradingDay(
    preStart: at(1_793_869_200),
    regularStart: at(1_793_889_000),
    regularEnd: at(1_793_912_400),
    postEnd: at(1_793_926_800)
)
private let friday = TradingDay(
    preStart: thursday.preStart.addingTimeInterval(86_400),
    regularStart: thursday.regularStart.addingTimeInterval(86_400),
    regularEnd: thursday.regularEnd.addingTimeInterval(86_400),
    postEnd: thursday.postEnd.addingTimeInterval(86_400)
)

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
private func minutes(_ m: Double, after date: Date) -> Date { date.addingTimeInterval(m * 60) }

private func snapshot(
    price: Double = 348.18,
    time: Date = minutes(40, after: thursday.regularStart),
    previousClose: Double? = 349.51,
    day: TradingDay = thursday,
    extendedHours: Bool = true,
    lastBar: Snapshot.Bar? = nil
) -> Snapshot {
    Snapshot(
        symbol: "AAPL", name: "Apple Inc.", currency: "USD", decimals: 2,
        price: price, time: time, previousClose: previousClose,
        day: day, hasExtendedHours: extendedHours, lastBar: lastBar
    )
}

private func tick(_ price: Double, _ time: Date, flag: Int = 1) -> Tick {
    Tick(symbol: "AAPL", price: price, time: time, marketHours: flag)
}

@Suite struct QuoteTests {
    @Test func movesAgainstPreviousClose() {
        let latest = Quote(snapshot: snapshot()).latest
        #expect(latest.session == .regular)
        #expect(abs(latest.change! - -1.33) < 1e-9)
        #expect(abs(latest.changePercent! - -0.380533) < 1e-5)
    }

    @Test func newerTradeWinsOlderIsDropped() {
        var quote = Quote(snapshot: snapshot())
        quote.apply(tick(350, minutes(41, after: thursday.regularStart)))
        #expect(quote.price == 350)
        // The stream running a minute behind.
        quote.apply(tick(340, minutes(39, after: thursday.regularStart)))
        #expect(quote.price == 350)
    }

    @Test func afterHoursSitsBesideTheClose() {
        var quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd))
        quote.apply(tick(350.00, minutes(12, after: thursday.regularEnd), flag: 2))
        #expect(quote.price == 349.30)
        let latest = quote.latest
        #expect(latest.session == .post)
        #expect(latest.price == 350.00)
        // Against the close, not the previous close.
        #expect(abs(latest.change! - 0.70) < 1e-9)
        #expect(Session.post.label == "After hours")
    }

    @Test func overnightSitsBesideTheClose() {
        var quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd))
        // 9:30 PM: past the day's windows, so Yahoo's flag 4 decides.
        quote.apply(tick(352.00, minutes(90, after: thursday.postEnd), flag: 4))
        #expect(quote.price == 349.30)
        #expect(quote.previousClose == 349.51)
        let latest = quote.latest
        #expect(latest.session == .overnight)
        #expect(latest.price == 352.00)
        // Against the close, as after hours is.
        #expect(abs(latest.change! - 2.70) < 1e-9)
        #expect(Session.overnight.label == "Overnight")
    }

    @Test func overnightDoesNotOpenANewDay() {
        let quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd))
        #expect(!quote.opensNewDay(tick(352, minutes(90, after: thursday.postEnd), flag: 4)))
        // Friday's pre-market does.
        #expect(quote.opensNewDay(tick(352, minutes(5, after: friday.preStart), flag: 0)))
    }

    @Test func closingPrintIsRegular() {
        var quote = Quote(snapshot: snapshot())
        quote.apply(tick(349.30, thursday.regularEnd))
        #expect(quote.extended == nil)
        #expect(quote.price == 349.30)
    }

    @Test func regularTradeClearsExtended() {
        var quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd, day: friday))
        quote.apply(tick(351, minutes(-60, after: friday.regularStart), flag: 0))
        #expect(quote.latest.session == .pre)
        quote.apply(tick(352, friday.regularStart))
        #expect(quote.extended == nil)
        #expect(quote.price == 352)
    }

    @Test func openingTradeMakesTheCloseThePreviousClose() {
        // Snapshot taken in Friday's pre-market: price is Thursday's close.
        var quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd, previousClose: 349.51, day: friday))
        quote.apply(tick(352, minutes(1, after: friday.regularStart)))
        #expect(quote.previousClose == 349.30)
        #expect(abs(quote.latest.change! - 2.70) < 1e-9)
    }

    @Test func tradePastTheKnownDayRollsItOver() {
        // The day on file is Thursday's; a regular trade arrives on Friday.
        var quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd))
        let t = minutes(5, after: friday.regularStart)
        #expect(quote.isPastDay(t))
        quote.apply(tick(352, t, flag: 1))
        #expect(quote.previousClose == 349.30)
        #expect(quote.price == 352)
    }

    @Test func noExtendedHoursMeansRegular() {
        var quote = Quote(snapshot: snapshot(extendedHours: false))
        quote.apply(tick(350, minutes(1, after: thursday.regularEnd), flag: 2))
        #expect(quote.extended == nil)
        #expect(quote.price == 350)
    }

    @Test func snapshotBarCarriesAfterHours() {
        let bar = Snapshot.Bar(price: 350.5, time: minutes(30, after: thursday.regularEnd))
        let quote = Quote(snapshot: snapshot(price: 349.30, time: thursday.regularEnd, lastBar: bar))
        #expect(quote.extended == ExtendedTrade(session: .post, price: 350.5, time: bar.time))
        // A bar inside the session is not an extended trade.
        let regular = Quote(snapshot: snapshot(lastBar: .init(price: 1, time: minutes(10, after: thursday.regularStart))))
        #expect(regular.extended == nil)
    }

    @Test func tradeAloneOnlyFromTheRegularSession() {
        #expect(Quote(tick: tick(1, .now, flag: 0)) == nil)
        let quote = Quote(tick: Tick(symbol: "AAPL", price: 348.18, time: .now, change: -1.33))
        #expect(quote?.previousClose == 349.51)
    }

    @Test func tradingHours() {
        let quote = Quote(snapshot: snapshot())
        #expect(quote.isTrading(at: minutes(-30, after: thursday.regularStart)))
        #expect(!quote.isTrading(at: minutes(1, after: thursday.postEnd)))
        let toronto = Quote(snapshot: snapshot(extendedHours: false))
        #expect(!toronto.isTrading(at: minutes(-30, after: thursday.regularStart)))
    }
}
