import Testing
@testable import EmuSupport

@Suite struct HashTests {
    @Test func crc32CheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func crc32IsIncremental() {
        var c = CRC32()
        c.update(Array("12345".utf8))
        c.update(Array("6789".utf8))
        #expect(c.value == 0xCBF4_3926)
    }

    @Test func xxh64KnownValues() {
        #expect(XXH64.hash([UInt8]()) == 0xEF46_DB37_51D8_E999)
        #expect(XXH64.hash(Array("a".utf8)) == 0xD24E_C4F1_A98C_6E5B)
    }

    @Test func xxh64LongInputIsStable() {
        let data = (0..<100).map { UInt8($0) }
        #expect(XXH64.hash(data) == XXH64.hash(data))
        #expect(XXH64.hash(data) != XXH64.hash(data, seed: 1))
    }
}

@Suite struct SHA1AndPNGTests {
    @Test func sha1KnownVectors() {
        #expect(SHA1.hexDigest([]) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(SHA1.hexDigest(Array("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(SHA1.hexDigest(Array("The quick brown fox jumps over the lazy dog".utf8)) == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
        // Crosses the 55/56-byte padding boundary and a block boundary.
        #expect(SHA1.hexDigest(Array(repeating: UInt8(ascii: "a"), count: 1_000)) == "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    @Test func pngHasValidStructure() {
        let pixels = [UInt8](repeating: 0x80, count: 4 * 4 * 4)
        let png = pixels.withUnsafeBytes { PNGEncoder.encode(bgra: $0, width: 4, height: 4, bytesPerRow: 16) }
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(String(decoding: png[12..<16], as: UTF8.self) == "IHDR")
        #expect(Array(png.suffix(12).prefix(4)) == [0, 0, 0, 0])      // IEND length
        #expect(String(decoding: png.suffix(8).prefix(4), as: UTF8.self) == "IEND")
    }
}
