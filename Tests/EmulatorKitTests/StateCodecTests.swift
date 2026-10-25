import Testing
@testable import EmulatorKit

@Suite struct StateCodecTests {
    @Test func roundTrip() throws {
        var w = StateWriter(system: "gba", gameHash: 0xDEAD_BEEF)
        w.chunk("CPU ", version: 2, [1, 2, 3, 4])
        w.chunk("RAM", [9, 9])
        var r = try StateReader(bytes: w.bytes)
        #expect(r.system == "gba")
        #expect(r.gameHash == 0xDEAD_BEEF)
        let a = try #require(try r.nextChunk())
        #expect(a.tag == "CPU " && a.version == 2 && a.payload == [1, 2, 3, 4])
        let b = try #require(try r.nextChunk())
        #expect(b.tag == "RAM " && b.payload == [9, 9])
        #expect(try r.nextChunk() == nil)
    }

    @Test func rejectsBadMagic() {
        #expect(throws: StateError.badMagic) { _ = try StateReader(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) }
    }

    @Test func rejectsTruncatedChunk() throws {
        var w = StateWriter(system: "gb", gameHash: 1)
        w.chunk("DATA", [1, 2, 3, 4, 5])
        var r = try StateReader(bytes: Array(w.bytes.dropLast(2)))
        #expect(throws: StateError.truncated) { _ = try r.nextChunk() }
    }

    @Test func fixedClock() {
        #expect(FixedClock(seconds: 42).unixSeconds() == 42)
    }
}
