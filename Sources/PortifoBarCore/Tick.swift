import Foundation

// One trade as Yahoo's streamer pushes it: the PricingData message behind
// finance.yahoo.com's live prices. Only the fields this app reads are kept.
public struct Tick: Sendable, Equatable {
    public var symbol: String
    public var price: Double
    // When the trade was struck.
    public var time: Date
    // Yahoo's session flag: 0 pre-market, 1 regular, 2 post-market, 3
    // extended, 4 overnight (8 PM to 4 AM New York; seen for NVDA and QQQ on
    // Nov 5, 2026). proto3 leaves a 0 off the wire, so a missing flag reads as 0.
    public var marketHours: Int
    // Yahoo's own move for the day. Its reference isn't always the previous
    // close the chart endpoints give (crypto's runs over a different 24 hours),
    // so a quote only falls back on it before a snapshot has arrived.
    public var change: Double?
    public var changePercent: Double?
    // Sent for crypto and indices only; a snapshot fills it in otherwise.
    public var currency: String?
    public var exchange: String?
    public var name: String?
    // Decimal places Yahoo quotes the price to (its "price hint").
    public var decimals: Int?

    public init(
        symbol: String,
        price: Double,
        time: Date,
        marketHours: Int = 1,
        change: Double? = nil,
        changePercent: Double? = nil,
        currency: String? = nil,
        exchange: String? = nil,
        name: String? = nil,
        decimals: Int? = nil
    ) {
        self.symbol = symbol
        self.price = price
        self.time = time
        self.marketHours = marketHours
        self.change = change
        self.changePercent = changePercent
        self.currency = currency
        self.exchange = exchange
        self.name = name
        self.decimals = decimals
    }
}

extension Tick {
    // Field numbers from Yahoo's pricing.proto, checked against live frames:
    // 1 id, 2 price (float), 3 time (sint64, epoch ms), 4 currency,
    // 5 exchange, 7 market hours (int32), 8 change percent (float),
    // 12 change (float), 13 short name, 27 price hint (sint64).
    public init?(pricingData bytes: [UInt8]) {
        var reader = ProtobufReader(bytes)
        var symbol: String?
        var price: Float?
        var millis: Int64?
        var marketHours = 0
        var change: Float?
        var changePercent: Float?
        var currency: String?
        var exchange: String?
        var name: String?
        var hint: Int64?
        do {
            while let entry = try reader.next() {
                let value = entry.value
                switch entry.field {
                case 1: symbol = value.string
                case 2: price = value.float
                case 3: millis = value.sint64
                case 4: currency = value.string
                case 5: exchange = value.string
                case 7: marketHours = Int(truncatingIfNeeded: value.int64 ?? 0)
                case 8: changePercent = value.float
                case 12: change = value.float
                case 13: name = value.string
                case 27: hint = value.sint64
                default: break
                }
            }
        } catch {
            return nil
        }
        guard let symbol, !symbol.isEmpty, let price, price.isFinite, price > 0 else { return nil }
        self.init(
            symbol: symbol,
            price: quoted(price),
            time: millis.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .now,
            marketHours: marketHours,
            change: change.flatMap { $0.isFinite ? quoted($0) : nil },
            changePercent: changePercent.flatMap { $0.isFinite ? quoted($0) : nil },
            currency: currency.flatMap { $0.isEmpty ? nil : $0 },
            exchange: exchange.flatMap { $0.isEmpty ? nil : $0 },
            name: name.flatMap { $0.isEmpty ? nil : $0 },
            decimals: hint.map { Int(clamping: $0) }
        )
    }

    // One text frame from the streamer. With `?version=2` each is JSON,
    // `{"type":"pricing","message":"<base64 PricingData>"}`; the original
    // protocol sent the base64 alone. Both are read.
    public init?(frame: String) {
        let payload: String
        if frame.hasPrefix("{") {
            guard
                let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(frame.utf8)),
                envelope.type == nil || envelope.type == "pricing",
                let message = envelope.message
            else { return nil }
            payload = message
        } else {
            payload = frame
        }
        guard let bytes = Data(base64Encoded: payload) else { return nil }
        self.init(pricingData: [UInt8](bytes))
    }
}

private struct Envelope: Decodable {
    let type: String?
    let message: String?
}

// The streamer sends prices as 32-bit floats, so 348.18 arrives as
// 348.17999267578125. A Float's description is the shortest decimal that
// reads back as that same Float, which recovers the price as it was quoted.
private func quoted(_ value: Float) -> Double {
    Double(value.description) ?? Double(value)
}
