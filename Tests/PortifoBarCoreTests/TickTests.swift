import Foundation
import Testing
@testable import PortifoBarCore

// A frame captured from wss://streamer.finance.yahoo.com/?version=2 on
// Nov 5, 2026: AAPL at 348.34, down 1.17 (−0.33%) in the regular session.
private let aaplMessage = "CgRBQVBMFYUrrkMY4NSOxLVoKgNOTVMwCDgBRW1lq75ItKu2DWUAw5W/sAGSBNgBBPUCAMOVv/0CbWWrvg=="

@Suite struct TickTests {
    @Test func decodesPricingData() throws {
        let tick = try #require(Tick(pricingData: [UInt8](Data(base64Encoded: aaplMessage)!)))
        #expect(tick.symbol == "AAPL")
        // 348.3399963378906 on the wire, as a 32-bit float.
        #expect(tick.price == 348.34)
        #expect(tick.time == Date(timeIntervalSince1970: 1_793_891_358))
        #expect(tick.marketHours == 1)
        #expect(tick.exchange == "NMS")
        #expect(tick.change == -1.1700134)
        #expect(tick.changePercent == -0.3347582)
        #expect(tick.decimals == 2)
        #expect(tick.currency == nil)
    }

    @Test func readsBothFrameFormats() throws {
        let v2 = try #require(Tick(frame: #"{"type":"pricing","message":"\#(aaplMessage)"}"#))
        let v1 = try #require(Tick(frame: aaplMessage))
        #expect(v1 == v2)
    }

    @Test func ignoresOtherFrames() {
        #expect(Tick(frame: #"{"type":"heartbeat"}"#) == nil)
        #expect(Tick(frame: "not base64!") == nil)
        // Truncated mid-field.
        #expect(Tick(pricingData: Array([UInt8](Data(base64Encoded: aaplMessage)!).prefix(9))) == nil)
    }

    @Test func zigzagAndSkipsUnknownFields() throws {
        // id "X" (1), price 2.5 (2), time -1 ms zigzag (3), an unknown
        // varint (99), an unknown fixed64 (100).
        var bytes: [UInt8] = [0x0A, 0x01, 0x58, 0x15]
        bytes += withUnsafeBytes(of: Float(2.5).bitPattern.littleEndian, Array.init)
        bytes += [0x18, 0x01]
        bytes += [0x98, 0x06, 0x05]
        bytes += [0xA1, 0x06] + [UInt8](repeating: 0, count: 8)
        let tick = try #require(Tick(pricingData: bytes))
        #expect(tick.symbol == "X")
        #expect(tick.price == 2.5)
        #expect(tick.time == Date(timeIntervalSince1970: -0.001))
        // No flag on the wire is proto3's zero: pre-market.
        #expect(tick.marketHours == 0)
    }
}

@Suite struct PriceFormatTests {
    let us = Locale(identifier: "en_US")

    @Test func prices() {
        #expect(PriceFormat.price(77337.75, decimals: 2, locale: us) == "77,337.75")
        #expect(PriceFormat.price(1.12143, decimals: 4, locale: us) == "1.1214")
    }

    @Test func signedMoves() {
        #expect(PriceFormat.change(1.33, decimals: 2, locale: us) == "+1.33")
        #expect(PriceFormat.change(-1.33, decimals: 2, locale: us) == "\u{2212}1.33")
        #expect(PriceFormat.percent(-0.38053, locale: us) == "\u{2212}0.38%")
        #expect(PriceFormat.percent(-0.001, locale: us) == "0.00%")
    }
}
