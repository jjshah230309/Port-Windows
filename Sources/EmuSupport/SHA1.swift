/// SHA-1, used only to identify ROM dumps (matching well-known hashes), never for security.
public struct SHA1 {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes {
            buffer.append(b)
            length &+= 1
            if buffer.count == 64 { processBlock(buffer); buffer.removeAll(keepingCapacity: true) }
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
            if buffer.count == 64 { processBlock(buffer); buffer.removeAll(keepingCapacity: true) }
        }
        for i in (0..<8).reversed() { buffer.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }
        processBlock(buffer)
        var out: [UInt8] = []
        for word in [h.0, h.1, h.2, h.3, h.4] { for i in (0..<4).reversed() { out.append(UInt8(truncatingIfNeeded: word >> (8 * UInt32(i)))) } }
        return out
    }

    private mutating func processBlock(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16 | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
        }
        for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
        var (a, b, c, d, e) = h
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
            default: f = b ^ c ^ d; k = 0xCA62_C1D6
            }
            let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = rotl(b, 30); b = a; a = t
        }
        h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
    }

    @inline(__always) private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var s = SHA1()
        s.update(bytes)
        return s.finalize()
    }

    public static func hexDigest(_ bytes: [UInt8]) -> String {
        hash(bytes).map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
    }
}
