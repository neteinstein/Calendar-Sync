import Foundation

/// The part of CBOR (RFC 8949) that security keys speak in CTAP2: integers, byte and text
/// strings, arrays, maps, booleans and null. Maps are encoded in CTAP2's canonical key order,
/// which security keys insist on.
public indirect enum CBOR: Hashable {
    case unsigned(UInt64)
    /// The integer -1 - n.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([CBOR: CBOR])
    case bool(Bool)
    case null

    public enum DecodingError: Error, Equatable {
        case truncated
        /// A kind of item this decoder doesn't read (tags, floats, indefinite lengths), by its
        /// first byte.
        case unsupported(UInt8)
        case invalidText
        case trailingBytes
    }

    public static func int(_ value: Int) -> CBOR {
        value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-1 - value))
    }

    public var intValue: Int? {
        switch self {
        case .unsigned(let n): return n <= UInt64(Int.max) ? Int(n) : nil
        case .negative(let n): return n <= UInt64(Int.max) ? -1 - Int(n) : nil
        default: return nil
        }
    }

    public var dataValue: Data? {
        if case .bytes(let data) = self { return data }
        return nil
    }

    public var stringValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var arrayValue: [CBOR]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public subscript(key: Int) -> CBOR? {
        if case .map(let map) = self { return map[.int(key)] }
        return nil
    }

    public subscript(key: String) -> CBOR? {
        if case .map(let map) = self { return map[.text(key)] }
        return nil
    }

    // MARK: - Encoding

    public var encoded: Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .unsigned(let n): Self.appendHead(0, n, to: &out)
        case .negative(let n): Self.appendHead(1, n, to: &out)
        case .bytes(let data):
            Self.appendHead(2, UInt64(data.count), to: &out)
            out += data
        case .text(let text):
            let data = Data(text.utf8)
            Self.appendHead(3, UInt64(data.count), to: &out)
            out += data
        case .array(let items):
            Self.appendHead(4, UInt64(items.count), to: &out)
            for item in items { item.encode(into: &out) }
        case .map(let map):
            Self.appendHead(5, UInt64(map.count), to: &out)
            // CTAP2 canonical order: by major type, then shorter keys first, then byte by byte.
            // That is the byte order of the encoded keys, since the major type and the length
            // come first in them. (Not RFC 7049's order, which puts length before major type.)
            let entries = map.map { (key: $0.key.encoded, value: $0.value) }
                .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            for entry in entries {
                out += entry.key
                entry.value.encode(into: &out)
            }
        case .bool(let value): out.append(value ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        }
    }

    /// The major type and its argument, in the shortest form.
    private static func appendHead(_ major: UInt8, _ value: UInt64, to out: inout Data) {
        let type = major << 5
        switch value {
        case ..<24: out.append(type | UInt8(value))
        case ..<0x100: out += [type | 24, UInt8(value)]
        case ..<0x1_0000: out.append(type | 25); appendBigEndian(UInt16(value), to: &out)
        case ..<0x1_0000_0000: out.append(type | 26); appendBigEndian(UInt32(value), to: &out)
        default: out.append(type | 27); appendBigEndian(value, to: &out)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { out += $0 }
    }

    // MARK: - Decoding

    /// Decodes one item that takes up all of `data`.
    public static func decode(_ data: Data) throws -> CBOR {
        var reader = Reader(bytes: [UInt8](data))
        let item = try reader.item(depth: 0)
        guard reader.offset == reader.bytes.count else { throw DecodingError.trailingBytes }
        return item
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: UInt64) throws -> ArraySlice<UInt8> {
            guard count <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
            defer { offset += Int(count) }
            return bytes[offset..<offset + Int(count)]
        }

        mutating func argument(_ info: UInt8, of initial: UInt8) throws -> UInt64 {
            let size: UInt64
            switch info {
            case ..<24: return UInt64(info)
            case 24: size = 1
            case 25: size = 2
            case 26: size = 4
            case 27: size = 8
            default: throw DecodingError.unsupported(initial)
            }
            return try take(size).reduce(0) { $0 << 8 | UInt64($1) }
        }

        /// A count of items still to come: each one takes at least one byte.
        mutating func count(_ info: UInt8, of initial: UInt8) throws -> Int {
            let count = try argument(info, of: initial)
            guard count <= UInt64(bytes.count - offset) else { throw DecodingError.truncated }
            return Int(count)
        }

        mutating func item(depth: Int) throws -> CBOR {
            let initial = try take(1).first!
            let major = initial >> 5, info = initial & 0x1F
            // Security keys nest a few levels deep at most.
            guard depth < 16 else { throw DecodingError.unsupported(initial) }
            switch major {
            case 0: return .unsigned(try argument(info, of: initial))
            case 1: return .negative(try argument(info, of: initial))
            case 2: return .bytes(Data(try take(argument(info, of: initial))))
            case 3:
                guard let text = String(bytes: try take(argument(info, of: initial)), encoding: .utf8) else {
                    throw DecodingError.invalidText
                }
                return .text(text)
            case 4:
                return .array(try (0..<count(info, of: initial)).map { _ in try item(depth: depth + 1) })
            case 5:
                var map: [CBOR: CBOR] = [:]
                for _ in 0..<(try count(info, of: initial)) {
                    let key = try item(depth: depth + 1)
                    map[key] = try item(depth: depth + 1)
                }
                return .map(map)
            case 7:
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22, 23: return .null // null, undefined
                default: throw DecodingError.unsupported(initial)
                }
            default: throw DecodingError.unsupported(initial)
            }
        }
    }
}
