import Foundation
import PortifoBarCore

// `PortifoBar --tail AAPL,^GSPC,BTC-USD`: the same store the menu bar runs
// on, printed line by line instead. For watching the feed itself: where each
// update came from, and how far behind the trade it arrived.
@MainActor
enum Tail {
    static func run(_ symbols: [String]) -> Never {
        // Line by line even into a pipe or a file.
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = QuoteStore()
        let clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3))
        store.onUpdate = { symbol, source in
            guard let quote = store.quotes[symbol] else { return }
            let latest = quote.latest
            let lag = Date.now.timeIntervalSince(latest.time)
            let move = latest.changePercent.map { PriceFormat.percent($0) } ?? "—"
            let session = latest.session.label.map { " \($0)" } ?? ""
            let via = source == .stream ? "stream" : "poll  "
            print(
                "\(Date.now.formatted(clock))  \(via)  \(symbol.padding(toLength: 9, withPad: " ", startingAt: 0))"
                    + " \(PriceFormat.price(latest.price, decimals: quote.decimals)) \(move)\(session)"
                    + "  (trade \(String(format: "%.1f", lag))s ago)"
            )
        }
        store.onStatusChange = {
            let error = store.lastError.map { "  error: \($0)" } ?? ""
            let lag = store.streamLag.map { String(format: " (%.1fs behind)", $0) } ?? ""
            print("\(Date.now.formatted(clock))  status  stream \(store.streamState)\(lag)\(error)")
        }
        store.track(symbols)
        RunLoop.main.run()
        exit(0)
    }
}
