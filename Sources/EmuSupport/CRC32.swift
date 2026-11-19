/// Standard CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320). Incremental, so a seed byte can be fed first.
public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { state = Self.table[Int((state ^ UInt32(b)) & 0xFF)] ^ (state >> 8) }
    }

    public var value: UInt32 { ~state }

    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c = CRC32()
        c.update(bytes)
        return c.value
    }
}
