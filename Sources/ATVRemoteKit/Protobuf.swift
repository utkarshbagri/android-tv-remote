import Foundation

// A deliberately tiny protobuf encoder/decoder: the Android TV Remote v2 messages only use
// varints, length-delimited bytes/strings and nested messages, so we hand-roll them instead of
// pulling in SwiftProtobuf + protoc. Field numbers mirror androidtvremote2's polo.proto and
// remotemessage.proto (see docs/PROTOCOL.md).

public struct ProtoWriter {
    public private(set) var data = Data()

    public init() {}

    public static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private mutating func tag(_ field: Int, _ wireType: Int) {
        data.append(Self.varint(UInt64(field << 3 | wireType)))
    }

    public mutating func uint(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        data.append(Self.varint(value))
    }

    public mutating func int(_ field: Int, _ value: Int) {
        uint(field, UInt64(bitPattern: Int64(value)))
    }

    public mutating func bool(_ field: Int, _ value: Bool) {
        uint(field, value ? 1 : 0)
    }

    public mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        data.append(Self.varint(UInt64(value.count)))
        data.append(value)
    }

    public mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    public mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

public enum ProtoError: Error {
    case truncated
    case unsupportedWireType(Int)
}

/// A parsed message: field number -> list of raw values (varints as UInt64, length-delimited as Data).
public struct ProtoMessage {
    public enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    public private(set) var fields: [Int: [Value]] = [:]

    public init(_ data: Data) throws {
        var reader = ProtoReader(data)
        while !reader.atEnd {
            let key = try reader.varint()
            let field = Int(key >> 3)
            switch Int(key & 7) {
            case 0: fields[field, default: []].append(.varint(try reader.varint()))
            case 1: try reader.skip(8)
            case 2: fields[field, default: []].append(.bytes(try reader.lengthDelimited()))
            case 5: try reader.skip(4)
            case let wt: throw ProtoError.unsupportedWireType(wt)
            }
        }
    }

    public func has(_ field: Int) -> Bool { fields[field] != nil }

    public func uint(_ field: Int) -> UInt64? {
        for case let .varint(v) in fields[field] ?? [] { return v }
        return nil
    }

    public func data(_ field: Int) -> Data? {
        for case let .bytes(d) in fields[field] ?? [] { return d }
        return nil
    }

    public func string(_ field: Int) -> String? {
        data(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func message(_ field: Int) -> ProtoMessage? {
        data(field).flatMap { try? ProtoMessage($0) }
    }
}

struct ProtoReader {
    private let data: Data
    private var pos: Data.Index

    init(_ data: Data) {
        self.data = data
        self.pos = data.startIndex
    }

    var atEnd: Bool { pos >= data.endIndex }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < data.endIndex else { throw ProtoError.truncated }
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoError.truncated }
        }
    }

    mutating func lengthDelimited() throws -> Data {
        let len = Int(try varint())
        guard data.endIndex - pos >= len else { throw ProtoError.truncated }
        defer { pos += len }
        return data.subdata(in: pos..<(pos + len))
    }

    mutating func skip(_ n: Int) throws {
        guard data.endIndex - pos >= n else { throw ProtoError.truncated }
        pos += n
    }
}

/// Splits a byte stream into varint-length-prefixed frames (the framing both ports use).
struct FrameBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    mutating func next() -> Data? {
        var reader = ProtoReader(buffer)
        guard let len = try? reader.varint() else { return nil }
        let headerLen = ProtoWriter.varint(len).count
        guard buffer.count >= headerLen + Int(len) else { return nil }
        let start = buffer.startIndex + headerLen
        let frame = buffer.subdata(in: start..<(start + Int(len)))
        buffer = buffer.subdata(in: (start + Int(len))..<buffer.endIndex)
        return frame
    }
}
