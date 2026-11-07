import Foundation

// One session's close, for the moving average.
public struct DailyClose: Sendable, Equatable {
    // Where its daily bar starts: the regular open, or midnight UTC for a
    // market that never closes.
    public var time: Date
    public var close: Double

    public init(time: Date, close: Double) {
        self.time = time
        self.close = close
    }
}

// Portifo's moving average (MarketService.getSma in packages/portifo-api):
// the simple average of the last `window` daily closes, read off at each of
// the chart's points.
public enum MovingAverage {
    public static let window = 200

    // The average at each point, given the points' times in order. A point
    // runs until the next one starts (the last one, until now), and it takes
    // the average of the closes of sessions that start before it ends. So a
    // daily point takes its own day's average, a weekly or monthly point its
    // last session's, and an intraday point its own session's: the line holds
    // still through a session and steps between them. A session's average
    // counts its own close, and today's counts the latest price. A pre-market
    // point takes the average up to the session before. A point without a
    // full window behind it gets none, so a young listing's line starts late.
    public static func values(at times: [Date], closes: [DailyClose], window: Int = window) -> [Double?] {
        var sum = 0.0
        var n = 0 // closes folded into the sum so far
        return times.indices.map { i in
            let end = i + 1 < times.count ? times[i + 1] : .distantFuture
            while n < closes.count, closes[n].time < end {
                sum += closes[n].close
                if n >= window { sum -= closes[n - window].close }
                n += 1
            }
            return n >= window ? sum / Double(window) : nil
        }
    }

    // How far back the closes must reach for a chart that starts at
    // `start`, so its first point already has a full window behind it: 7
    // calendar days for every 5 sessions, plus three weeks for holidays.
    public static func closesStart(for start: Date, window: Int = window) -> Date {
        let days = (window * 7 + 4) / 5 + 21
        return start.addingTimeInterval(-Double(days) * 86_400)
    }
}

// Portifo's SMA bands (HoldingChart in packages/portifo-web): the 200-day
// average, and lines 5, 10 and 15% either side of it. Only the lines the
// price crosses set the scale, so the price keeps its own. Of the bands,
// only those are drawn. The average is always drawn, but when the price
// stays on one side of it, it doesn't stretch the scale.
public struct SMABands: Sendable, Equatable {
    public struct Level: Sendable, Hashable {
        // Its distance from the average: 0.05 is 5% above it.
        public let offset: Double
        // A band is named by its distance: "+15%", "−5%".
        public let label: String

        public var isAverage: Bool { offset == 0 }
    }

    // Top down.
    public static let levels: [Level] = [
        Level(offset: 0.15, label: "+15%"),
        Level(offset: 0.10, label: "+10%"),
        Level(offset: 0.05, label: "+5%"),
        Level(offset: 0, label: "SMA"),
        Level(offset: -0.05, label: "\u{2212}5%"),
        Level(offset: -0.10, label: "\u{2212}10%"),
        Level(offset: -0.15, label: "\u{2212}15%"),
    ]

    // The average at each point, nil where there isn't a full window yet.
    public let average: [Double?]
    // How far the price got from the average: its lowest and highest
    // distance, as fractions of the average.
    public let low: Double
    public let high: Double
    // The lines to draw, top down: the average, always, and the bands the
    // price crosses. The price moves continuously, so it crosses every band
    // between its lowest and highest distance.
    public let drawn: [Level]

    // Nil when no point has an average.
    public init?(prices: [Double], average: [Double?]) {
        let distances = zip(prices, average).compactMap { price, average in
            average.flatMap { $0 > 0 ? price / $0 - 1 : nil }
        }
        guard let low = distances.min(), let high = distances.max() else { return nil }
        self.average = average
        self.low = low
        self.high = high
        drawn = Self.levels.filter { $0.isAverage || (low...high).contains($0.offset) }
    }

    // Whether the price crosses the line, which then sets the scale.
    public func crosses(_ level: Level) -> Bool {
        (low...high).contains(level.offset)
    }

    // When the price crosses none of the lines, not even the average, the
    // lines it stayed between: the nearest above its high and the nearest
    // below its low. "Stayed between +5% and the SMA".
    public var stayed: String? {
        guard !Self.levels.contains(where: crosses) else { return nil }
        func name(_ level: Level) -> String { level.isAverage ? "the SMA" : level.label }
        let above = Self.levels.last { $0.offset > high }
        let below = Self.levels.first { $0.offset < low }
        switch (above, below) {
        case let (above?, below?): return "Stayed between \(name(above)) and \(name(below))"
        case let (above?, nil): return "Stayed below \(name(above))"
        case let (nil, below?): return "Stayed above \(name(below))"
        case (nil, nil): return nil
        }
    }

    // How far the price at point `i` sits from the average, in percent.
    public func gap(at i: Int, price: Double) -> Double? {
        guard let average = average[safe: i] ?? nil, average > 0 else { return nil }
        return (price / average - 1) * 100
    }
}
