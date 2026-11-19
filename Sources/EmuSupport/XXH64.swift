/// xxHash64, used for framebuffer and audio regression hashes in the headless test runner.
public enum XXH64 {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    public static func hash(_ data: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let n = data.count
        var p = 0
        func read64(_ at: Int) -> UInt64 { UInt64(littleEndian: data.loadUnaligned(fromByteOffset: at, as: UInt64.self)) }
        func read32(_ at: Int) -> UInt32 { UInt32(littleEndian: data.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }

        var h: UInt64
        if n >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            while p + 32 <= n {
                v1 = round(v1, read64(p))
                v2 = round(v2, read64(p + 8))
                v3 = round(v3, read64(p + 16))
                v4 = round(v4, read64(p + 24))
                p += 32
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1)
            h = merge(h, v2)
            h = merge(h, v3)
            h = merge(h, v4)
        } else {
            h = seed &+ p5
        }
        h &+= UInt64(n)

        while p + 8 <= n {
            h ^= round(0, read64(p))
            h = rotl(h, 27) &* p1 &+ p4
            p += 8
        }
        if p + 4 <= n {
            h ^= UInt64(read32(p)) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            p += 4
        }
        while p < n {
            h ^= UInt64(data[p]) &* p5
            h = rotl(h, 11) &* p1
            p += 1
        }
        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }

    public static func hash(_ bytes: [UInt8], seed: UInt64 = 0) -> UInt64 {
        bytes.withUnsafeBytes { hash($0, seed: seed) }
    }
}
