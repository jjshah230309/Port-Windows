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
