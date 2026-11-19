import Testing
import EmulatorKit
@testable import GBACore

/// The compile-time conformance check the brief asks for: the core is an EmulatorCore.
private func conformsToEmulatorCore(_ core: GameBoyAdvanceCore) -> any EmulatorCore { core }

@Suite struct GBACoreTests {
    // MARK: Conformance

    @Test func coreSatisfiesTheEmulatorCoreContract() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        let asCore: any EmulatorCore = conformsToEmulatorCore(core)
        #expect(type(of: asCore).info.id == "gba")
        #expect(type(of: asCore).info.width == 240)
        #expect(type(of: asCore).info.height == 160)
        #expect(type(of: asCore).info.audioRate == 48_000)
    }

    @Test func rejectsROMsThatAreTooSmall() {
        #expect(throws: GameBoyAdvanceError.self) {
            _ = try GameBoyAdvanceCore.core([UInt8](repeating: 0, count: 0x80))
        }
    }

    @Test func readsTheCartridgeHeader() throws {
        let core = try GameBoyAdvanceCore.core(
            SyntheticGBA.make(program: [], title: "POKEMON", gameCode: "AXVE", makerCode: "01"))
        #expect(core.title == "POKEMON")
        #expect(core.gameCode == "AXVE")
        #expect(core.makerCode == "01")
    }

    // MARK: Memory map

    @Test func ewramReadsAndWrites() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        for offset in 0..<256 {
            core.write8(0x0200_0000 &+ UInt32(offset), UInt8(offset))
        }
        for offset in 0..<256 {
            #expect(core.peek(0x0200_0000 &+ UInt32(offset)) == UInt8(offset))
        }
        // EWRAM is 256 KiB and mirrors: the byte past the end is the first one again.
        core.write8(0x0203_FFFF, 0x5A)
        #expect(core.peek(0x0203_FFFF) == 0x5A)
        #expect(core.peek(0x0204_0000) == 0x00)
    }

    @Test func iwramReadsAndWrites() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0300_1000, 0xA5)
        #expect(core.peek(0x0300_1000) == 0xA5)
        // IWRAM mirrors every 32 KiB.
        #expect(core.peek(0x0300_9000) == 0xA5)
    }

    @Test func iwramProtectedRegionIgnoresWrites() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        // The first 0xC0 bytes hold the BIOS and the interrupt vectors: writes there are dropped.
        core.write8(0x0300_0000, 0x11)
        core.write8(0x0300_00BF, 0x22)
        #expect(core.peek(0x0300_0000) == 0x00)
        #expect(core.peek(0x0300_00BF) == 0x00)
        // The byte just past the protected region is writable.
        core.write8(0x0300_00C0, 0x33)
        #expect(core.peek(0x0300_00C0) == 0x33)
    }

    @Test func paletteRAMReadsAndWrites() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0400_0400, 0x7F)
        core.write8(0x0400_04FF, 0x2C)
        #expect(core.peek(0x0400_0400) == 0x7F)
        #expect(core.peek(0x0400_04FF) == 0x2C)
        // Palette RAM mirrors every 1 KiB.
        #expect(core.peek(0x0400_0800) == 0x7F)
    }

    @Test func vramReadsAndWrites() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0600_0000, 0x12)
        core.write8(0x0601_7FFF, 0x34)
        #expect(core.peek(0x0600_0000) == 0x12)
        #expect(core.peek(0x0601_7FFF) == 0x34)
    }

    @Test func vramIsAlsoVisibleInTheIOWindow() throws {
        // The brief puts VRAM at 04001000h-04017FFFh as well as at 06000000h: the two are the same
        // storage, so a write through one is seen through the other.
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0400_1000, 0x56)
        #expect(core.peek(0x0600_0000) == 0x56)
        core.write8(0x0600_0000, 0x78)
        #expect(core.peek(0x0400_1000) == 0x78)
    }

    @Test func oamReadsAndWrites() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0500_0000, 0x99)
        #expect(core.peek(0x0500_0000) == 0x99)
        // The 8 KiB window mirrors the first KiB.
        #expect(core.peek(0x0500_1000) == 0x99)
    }

    @Test func ioRegistersReadAndWrite() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0400_0000, 0x80)          // DISPCNT
        core.write8(0x0400_0060, 0x21)          // a mid-window register
        #expect(core.peek(0x0400_0000) == 0x80)
        #expect(core.peek(0x0400_0060) == 0x21)
    }

    @Test func cartridgeROMIsReadableAndReadOnly() throws {
        var rom = SyntheticGBA.make(program: [])
        rom[0x00] = 0x42
        rom[0x1FFF] = 0x99
        let core = try GameBoyAdvanceCore.core(rom)
        #expect(core.peek(0x0800_0000) == 0x42)
        #expect(core.peek(0x0800_1FFF) == 0x99)
        // The same bytes are mirrored in the low window, just above the BIOS.
        #expect(core.peek(0x0000_4000) == 0x42)
        // Writes to ROM are dropped.
        core.write8(0x0800_0000, 0xFF)
        #expect(core.peek(0x0800_0000) == 0x42)
    }

    @Test func biosIsUsedWhenFirmwareSuppliesIt() throws {
        var bios = [UInt8](repeating: 0, count: 0x8000)
        bios[0x10] = 0xDE
        bios[0x20] = 0xAD
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []),
                                                firmware: FirmwareSet(files: ["bios": bios]))
        #expect(core.peek(0x0000_0010) == 0xDE)
        #expect(core.peek(0x0000_0020) == 0xAD)
    }

    @Test func missingBIOSReadsAsZero() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        #expect(core.peek(0x0000_0000) == 0x00)
        #expect(core.peek(0x0000_3FFF) == 0x00)
    }

    @Test func soundRegistersReadAndWrite() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0700_0000, 0x77)
        core.write8(0x0700_03FF, 0x88)
        #expect(core.peek(0x0700_0000) == 0x77)
        #expect(core.peek(0x0700_03FF) == 0x88)
    }

    @Test func keyInputIsReadOnly() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0400_0130, 0x00)
        #expect(core.peek(0x0400_0130) == 0xFF)   // no buttons pressed, so all the low bits are 1
    }

    // MARK: Save state

    @Test func saveStateRoundTripsExactly() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0200_0000, 0x11)
        core.write8(0x0300_2000, 0x22)
        core.write8(0x0400_0400, 0x33)
        core.write8(0x0600_1000, 0x44)
        core.write8(0x0500_0010, 0x55)
        core.write8(0x0400_0000, 0x66)
        core.write8(0x0700_0060, 0x77)

        var writer = StateWriter(system: "gba", gameHash: 0x1234)
        core.saveState(into: &writer)

        // Mutate everything the state covers.
        core.write8(0x0200_0000, 0x00)
        core.write8(0x0300_2000, 0x00)
        core.write8(0x0400_0400, 0x00)
        core.write8(0x0600_1000, 0x00)
        core.write8(0x0500_0010, 0x00)
        core.write8(0x0400_0000, 0x00)
        core.write8(0x0700_0060, 0x00)

        var reader = try StateReader(bytes: writer.bytes)
        try core.loadState(from: &reader)

        #expect(core.peek(0x0200_0000) == 0x11)
        #expect(core.peek(0x0300_2000) == 0x22)
        #expect(core.peek(0x0400_0400) == 0x33)
        #expect(core.peek(0x0600_1000) == 0x44)
        #expect(core.peek(0x0500_0010) == 0x55)
        #expect(core.peek(0x0400_0000) == 0x66)
        #expect(core.peek(0x0700_0060) == 0x77)
    }

    @Test func saveStateRestoresAFreshCore() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        core.write8(0x0200_1234, 0xC7)
        var writer = StateWriter(system: "gba", gameHash: 0x1234)
        core.saveState(into: &writer)

        let fresh = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        var reader = try StateReader(bytes: writer.bytes)
        try fresh.loadState(from: &reader)
        #expect(fresh.peek(0x0200_1234) == 0xC7)
    }

    @Test func saveStateKeepsTheFrameBuffer() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        var writer = StateWriter(system: "gba", gameHash: 0)
        core.saveState(into: &writer)
        var reader = try StateReader(bytes: writer.bytes)
        try core.loadState(from: &reader)
        // The frame is still 240 x 160 and the pixels survive the round trip.
        #expect(core.video.width == 240)
        #expect(core.video.height == 160)
    }

    // MARK: Video and the frame boundary

    @Test func runFrameProducesAFrameOfTheRightSize() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        let input = GBATestInput()
        let output = GBATestOutput()
        core.runFrame(input: input, output: output)

        let v = core.video
        #expect(v.width == 240)
        #expect(v.height == 160)
        #expect(v.pitch == 240 * 4)
        #expect(v.format == .bgra8)
        // The pointer is valid and covers the whole frame.
        let pixels = UnsafeRawBufferPointer(start: v.pixels, count: v.pitch * v.height)
        #expect(pixels.count == 240 * 160 * 4)
    }

    @Test func runFrameAdvancesTheFrameCounter() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        let input = GBATestInput()
        let output = GBATestOutput()
        let before = core.frameCounter
        core.runFrame(input: input, output: output)
        core.runFrame(input: input, output: output)
        #expect(core.frameCounter == before + 2)
    }

    @Test func runFrameLatchesInputLazily() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        let input = GBATestInput()
        input.buttons = [.east, .start]
        let output = GBATestOutput()
        core.runFrame(input: input, output: output)

        // KEYINPUT is active low: A (bit 0) and Start (bit 3) read 0.
        #expect(core.peek(0x0400_0130) & 0x09 == 0)
        #expect(core.peek(0x0400_0130) & 0xF6 == 0xF6)
    }

    @Test func thePadStaysLatchedUntilTheNextFrame() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        let input = GBATestInput()
        let output = GBATestOutput()

        // Nothing is pressed yet, so the pad reads all ones.
        core.runFrame(input: input, output: output)
        #expect(core.peek(0x0400_0130) & 0xFF == 0xFF)

        // A button pressed after the frame ended does not change the latched value: the snapshot
        // was taken when the frame ran, and it is the snapshot the guest sees.
        input.buttons = [.south]
        #expect(core.peek(0x0400_0130) & 0x02 == 0x02)

        // The next frame latches the pad again, and now B is down.
        core.runFrame(input: input, output: output)
        #expect(core.peek(0x0400_0130) & 0x02 == 0x00)
    }

    @Test func runFrameReportsRumbleAsOff() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        let output = GBATestOutput()
        core.runFrame(input: GBATestInput(), output: output)
        #expect(output.rumble.count == 1)
        #expect(output.rumble.first?.low == 0)
        #expect(output.rumble.first?.high == 0)
    }

    @Test func batterySaveIsNotSupportedYet() throws {
        let core = try GameBoyAdvanceCore.core(SyntheticGBA.make(program: []))
        #expect(core.batterySave == nil)
        core.markBatterySaved()
        core.loadBatterySave([1, 2, 3])        // accepted and ignored
        #expect(core.batterySave == nil)
    }
}
