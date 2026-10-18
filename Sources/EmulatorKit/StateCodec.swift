public enum StateError: Error, Equatable {
    case badMagic
    case unsupportedVersion(UInt16)
    case truncated
}

/// Save-state container: "ATST", version, system id, game hash, then tagged chunks [tag(4), version(2), length(4), bytes].
public struct StateWriter {
    public static let magic: [UInt8] = Array("ATST".utf8)
    public static let formatVersion: UInt16 = 1

    public private(set) var bytes: [UInt8] = []

    public init(system: String, gameHash: UInt64) {
        bytes += Self.magic
        append(Self.formatVersion)
        let id = Array(system.utf8)
        append(UInt16(id.count))
        bytes += id
        append(gameHash)
    }

    public mutating func chunk(_ tag: String, version: UInt16 = 1, _ payload: [UInt8]) {
        var t = Array(tag.utf8.prefix(4))
        while t.count < 4 { t.append(0x20) }
        bytes += t
        append(version)
        append(UInt32(payload.count))
        bytes += payload
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { bytes += $0 }
    }
}

public struct StateReader {
    public let system: String
    public let gameHash: UInt64
    private let bytes: [UInt8]
    private var offset: Int

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        var o = 0
        guard bytes.count >= 4, Array(bytes[0..<4]) == StateWriter.magic else { throw StateError.badMagic }
        o = 4
        let version: UInt16 = try Self.read(bytes, &o)
        guard version == StateWriter.formatVersion else { throw StateError.unsupportedVersion(version) }
        let idLen: UInt16 = try Self.read(bytes, &o)
        guard o + Int(idLen) <= bytes.count else { throw StateError.truncated }
        system = String(decoding: bytes[o..<(o + Int(idLen))], as: UTF8.self)
        o += Int(idLen)
        gameHash = try Self.read(bytes, &o)
        offset = o
    }

    /// Returns the next chunk, or nil at the end of the stream.
    public mutating func nextChunk() throws -> (tag: String, version: UInt16, payload: [UInt8])? {
        if offset == bytes.count { return nil }
        guard offset + 4 <= bytes.count else { throw StateError.truncated }
        let tag = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
        offset += 4
        let version: UInt16 = try Self.read(bytes, &offset)
        let length: UInt32 = try Self.read(bytes, &offset)
        guard offset + Int(length) <= bytes.count else { throw StateError.truncated }
        let payload = Array(bytes[offset..<(offset + Int(length))])
        offset += Int(length)
        return (tag, version, payload)
    }

    private static func read<T: FixedWidthInteger>(_ bytes: [UInt8], _ o: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard o + size <= bytes.count else { throw StateError.truncated }
        var value: T = 0
        for i in 0..<size { value |= T(truncatingIfNeeded: bytes[o + i]) << (8 * i) }
        o += size
        return value
    }
}
