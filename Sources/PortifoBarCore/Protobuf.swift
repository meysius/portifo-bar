// Just enough of the protobuf wire format to read Yahoo's PricingData: no
// schema compiler and no dependency. A field this app doesn't read is skipped
// by its wire type, so fields Yahoo adds later pass harmlessly (it already
// sends 46 and 47, which no published schema names).
struct ProtobufReader {
    enum Failure: Error { case truncated, malformed }

    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    // The next field, or nil at the end of the message.
    mutating func next() throws -> (field: Int, value: Value)? {
        guard offset < data.count else { return nil }
        let key = try varint()
        let field = Int(truncatingIfNeeded: key >> 3)
        switch key & 7 {
        case 0:
            return (field, .varint(try varint()))
        case 1:
            return (field, .fixed64(try fixed(8)))
        case 2:
            let length = try varint()
            guard length <= UInt64(data.count - offset) else { throw Failure.truncated }
            let end = offset + Int(length)
            defer { offset = end }
            return (field, .bytes(data[offset..<end]))
        case 5:
            return (field, .fixed32(UInt32(truncatingIfNeeded: try fixed(4))))
        default:
            // Groups (3, 4) are long deprecated; nothing else is valid.
            throw Failure.malformed
        }
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.count else { throw Failure.truncated }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw Failure.malformed }
        }
    }

    // Little-endian, as the wire format stores fixed-width fields.
    private mutating func fixed(_ size: Int) throws -> UInt64 {
        guard data.count - offset >= size else { throw Failure.truncated }
        var result: UInt64 = 0
        for i in 0..<size {
            result |= UInt64(data[offset + i]) << (8 * UInt64(i))
        }
        offset += size
        return result
    }
}

extension ProtobufReader.Value {
    var float: Float? {
        if case .fixed32(let bits) = self { return Float(bitPattern: bits) }
        return nil
    }

    var double: Double? {
        if case .fixed64(let bits) = self { return Double(bitPattern: bits) }
        return nil
    }

    // int32 and int64: a plain varint, two's complement.
    var int64: Int64? {
        if case .varint(let raw) = self { return Int64(bitPattern: raw) }
        return nil
    }

    // sint32 and sint64: zigzag-encoded, so small negatives stay short.
    var sint64: Int64? {
        if case .varint(let raw) = self { return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1))) }
        return nil
    }

    var string: String? {
        if case .bytes(let bytes) = self { return String(decoding: bytes, as: UTF8.self) }
        return nil
    }
}
