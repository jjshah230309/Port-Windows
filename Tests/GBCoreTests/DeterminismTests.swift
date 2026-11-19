import Testing
import EmulatorKit
import EmuSupport
@testable import GBCore

/// A program that exercises timer + VBlank interrupts, sound, scrolling and VRAM, so a save state that misses any
/// piece of machine state makes the second run diverge from the first.
private func busyROM(cgb: Bool) -> [UInt8] {
    var p: [UInt8] = []
    p += [0x3E, 0x80, 0xE0, 0x26, 0x3E, 0x77, 0xE0, 0x24, 0x3E, 0xFF, 0xE0, 0x25]        // sound on, volume, panning
    p += [0x3E, 0xF3, 0xE0, 0x12, 0x3E, 0x80, 0xE0, 0x11, 0x3E, 0x00, 0xE0, 0x13, 0x3E, 0xC4, 0xE0, 0x14]
    p += [0x21, 0x00, 0x80, 0x06, 0x10, 0x78, 0xEE, 0x5A, 0x22, 0x05, 0x20, 0xF9]         // fill tile 0
    p += [0x3E, 0xE4, 0xE0, 0x47]                                                         // BGP
    p += [0x3E, 0x05, 0xE0, 0xFF, 0x3E, 0x05, 0xE0, 0x07, 0xFB]                           // IE=VBlank|Timer, TAC, EI
    p += [0x76, 0x00, 0x18, 0xFC]                                                         // HALT; NOP; JR loop
    let vblank: [UInt8] = [0x21, 0x00, 0xC0, 0x34, 0xF0, 0x43, 0x3C, 0xE0, 0x43, 0xD9]    // counter++, SCX++
    let timer: [UInt8] = [0x21, 0x01, 0xC0, 0x34, 0x7E, 0xE0, 0x13, 0xD9]                 // counter2++, change pitch
    return SyntheticROM.make(program: p, cgb: cgb, at: [0x40: vblank, 0x50: timer])
}

private func audioChecksum(_ core: GameBoyCore, frames: Int) -> (UInt64, UInt64) {
    var crc = CRC32()
    let input = TestInput(), output = TestOutput()
    for _ in 0..<frames {
        core.runFrame(input: input, output: output)
        core.drainAudio { buf in
            for s in buf { crc.update([UInt8(truncatingIfNeeded: s), UInt8(truncatingIfNeeded: s >> 8)]) }
        }
    }
    let v = core.video
    let hash = XXH64.hash(UnsafeRawBufferPointer(start: v.pixels, count: v.pitch * v.height))
    return (UInt64(crc.value), hash)
}

@Suite struct DeterminismTests {
    @Test(arguments: [false, true])
    func saveStateRestoresExactly(cgb: Bool) throws {
        let rom = busyROM(cgb: cgb)
        let a = try SyntheticROM.core(rom)
        a.run(frames: 120)
        var writer = StateWriter(system: "gb", gameHash: XXH64.hash(rom))
        a.saveState(into: &writer)
        let straight = audioChecksum(a, frames: 120)

        // Same core: load the state back and replay.
        var reader = try StateReader(bytes: writer.bytes)
        try a.loadState(from: &reader)
        let replay = audioChecksum(a, frames: 120)
        #expect(replay == straight)

        // A brand-new core restored from the same bytes must agree too.
        let b = try SyntheticROM.core(rom)
        var reader2 = try StateReader(bytes: writer.bytes)
        try b.loadState(from: &reader2)
        let fresh = audioChecksum(b, frames: 120)
        #expect(fresh == straight)
    }

    @Test func busyProgramActuallyRuns() throws {
        let core = try SyntheticROM.core(busyROM(cgb: false))
        core.run(frames: 120)
        #expect(core.peek(0xC000) >= 100)       // VBlank handler ran about once per frame
        #expect(core.peek(0xC001) > 0)          // timer handler ran
    }

    @Test func identicalRunsProduceIdenticalOutput() throws {
        let rom = busyROM(cgb: true)
        let x = audioChecksum(try SyntheticROM.core(rom), frames: 100)
        let y = audioChecksum(try SyntheticROM.core(rom), frames: 100)
        #expect(x == y)
    }
}
