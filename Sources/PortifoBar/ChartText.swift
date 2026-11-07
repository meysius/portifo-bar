import Foundation
import PortifoBarCore

// How a point on the chart reads in words: the stretch its bar spans, or for
// a lone trade, its time.
enum CandleText {
    // "12:40–12:45 PM · After hours", "9:34 PM · Overnight".
    static func when(_ candle: Candle, span: CandleSpan, in series: CandleSeries) -> String {
        [Self.span(candle, span: span, in: series), candle.session.label]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // Its minutes on the day's chart, "12:40–12:45 PM" (AM or PM once,
    // unless the span crosses noon), and with the weekday over a week or a
    // month, or a day that runs over two dates (yesterday before the open,
    // or the last 24 hours), "Mon 12:40–12:45 PM". Beyond, its day, week, month, quarter or
    // year: "Thu, Nov 5, 2026", "Week of Nov 2, 2026", "Nov 2026", "Q4 2026",
    // "2026". An overnight point is a single trade: "9:34 PM".
    static func span(_ candle: Candle, span: CandleSpan, in series: CandleSeries) -> String {
        let (range, timeZone) = (series.range, series.timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func format(_ style: Date.FormatStyle) -> String {
            var style = style
            style.timeZone = timeZone
            return candle.time.formatted(style)
        }
        let year = calendar.component(.year, from: candle.time)
        switch span {
        case .minutes(let minutes):
            let end = series.end(of: candle.time, span)
            let sameHalf = (calendar.component(.hour, from: candle.time) < 12) == (calendar.component(.hour, from: end) < 12)
            let start = sameHalf ? Clock.bare(candle.time, in: timeZone) : Clock.time(candle.time, in: timeZone)
            let lone = minutes == 1 || candle.session == .overnight
            let times = lone ? Clock.time(candle.time, in: timeZone) : "\(start)–\(Clock.time(end, in: timeZone))"
            return range == .day && !series.spansDays ? times : "\(format(.dateTime.weekday(.abbreviated))) \(times)"
        case .day:
            return format(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        case .week:
            return "Week of \(format(.dateTime.month(.abbreviated).day().year()))"
        case .month:
            return format(.dateTime.month(.abbreviated).year())
        case .quarter:
            return "Q\((calendar.component(.month, from: candle.time) - 1) / 3 + 1) \(year)"
        case .year:
            return String(year)
        }
    }

    // Shares traded, compact: "303M".
    static func volume(_ volume: Double) -> String {
        volume.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}

// Times of day as the reader's clock tells them.
enum Clock {
    // Whether that clock runs to twelve hours, with AM and PM.
    static let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)
        .map { $0.contains { "abB".contains($0) } } ?? false

    // "9:30 AM", or "09:30" on a 24-hour clock.
    static func time(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle().hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    // "9:30", AM or PM left to the reader. Date.FormatStyle leaves them off
    // only by padding the hour in some locales ("09:30" in en_CA).
    static func bare(_ date: Date, in timeZone: TimeZone) -> String {
        guard twelveHour else { return time(date, in: timeZone) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let style = Date.VerbatimFormatStyle(
            format: "\(hour: .defaultDigits(clock: .twelveHour, hourCycle: .oneBased)):\(minute: .twoDigits)",
            timeZone: timeZone,
            calendar: calendar
        )
        return date.formatted(style)
    }
}
