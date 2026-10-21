import Testing
@testable import GBACore

@Suite struct GBACartridgeTests {
    @Test func validROMParses() throws {
        let rom = SyntheticGBA.make(program: [0x00, 0xF0], title: "SYNTH", gameCode: "ATSE",
                                    makerCode: "01", romSizeCode: 2, ramSizeCode: 3,
                                    destinationCode: 0x41, developerID: 0x07, version: 0x0201)
        let info = try GBACartridge.parse(rom)
        #expect(info.title == "SYNTH")
        #expect(info.gameCode == "ATSE")
        #expect(info.makerCode == "01")
        #expect(info.romBytes == 0x20000)
        #expect(info.ramBytes == 32768)
        #expect(info.destinationCode == 0x41)
        #expect(info.developerID == 0x07)
        #expect(info.version == 0x0201)
    }

    @Test func romSizeComesFromTheHeaderNotTheFile() throws {
        // The file is 32 KiB long but the header claims 512 KiB: the header wins.
        let rom = SyntheticGBA.make(program: [0x00], romSizeCode: 4, fileBytes: 0x8000)
        let info = try GBACartridge.parse(rom)
        #expect(info.romBytes == 0x80000)
        #expect(rom.count == 0x8000)
    }

    @Test func tooSmallROMThrowsInvalidROM() {
        #expect(throws: GBACartridgeError.self) { _ = try GBACartridge.parse([UInt8](repeating: 0, count: 0xBF)) }
        #expect(throws: GBACartridgeError.invalidROM("file is smaller than a cartridge header")) {
            _ = try GBACartridge.parse([UInt8](repeating: 0, count: 0x10))
        }
    }

    @Test func brokenComplementCheckThrowsUnsupportedROM() {
        let rom = SyntheticGBA.make(program: [0x00], breakComplement: true)
        #expect(throws: GBACartridgeError.self) { _ = try GBACartridge.parse(rom) }
        #expect(throws: GBACartridgeError.unsupportedROM("complement check at 0xBD does not match the header")) {
            _ = try GBACartridge.parse(rom)
        }
    }

    @Test func unknownROMSizeCodeThrowsUnsupportedROM() {
        let rom = SyntheticGBA.make(program: [0x00], romSizeCode: 200)
        #expect(throws: GBACartridgeError.unsupportedROM("unknown ROM size code 200 at 0xE0")) {
            _ = try GBACartridge.parse(rom)
        }
    }

    @Test func wrongFixedValueThrowsUnsupportedROM() {
        let rom = SyntheticGBA.make(program: [0x00], fixedValue: 0x00)
        #expect(throws: GBACartridgeError.unsupportedROM("fixed value at 0xB2 is not 96h")) {
            _ = try GBACartridge.parse(rom)
        }
    }

    @Test func titleIsTrimmedOfPaddingAndJunk() throws {
        // "ZER" then zero padding, so the rest of the field never reaches the parser.
        let rom = SyntheticGBA.make(program: [0x00], title: "ZER")
        #expect(try GBACartridge.parse(rom).title == "ZER")

        // A title that fills the 12 byte field survives untouched.
        let full = SyntheticGBA.make(program: [0x00], title: "TWELVECHARAC")
        #expect(try GBACartridge.parse(full).title == "TWELVECHARAC")

        // A longer title is cut at the width of the field.
        let long = SyntheticGBA.make(program: [0x00], title: "THIRTEENCHARS")
        #expect(try GBACartridge.parse(long).title == "THIRTEENCHAR")

        // Unprintable bytes are dropped and trailing spaces are trimmed.
        var junk = SyntheticGBA.make(program: [0x00], title: "A")
        junk[0xA1] = 0x01; junk[0xA2] = 0x7F; junk[0xA3] = 0x42
        junk[0xA4] = 0x20; junk[0xA5] = 0x20
        SyntheticGBA.fixComplement(&junk)
        #expect(try GBACartridge.parse(junk).title == "AB")
    }

    @Test func everyROMSizeCodeParses() throws {
        for code in 0..<UInt8(SyntheticGBA.romSizes.count) {
            let rom = SyntheticGBA.make(program: [0x00], romSizeCode: code)
            let info = try GBACartridge.parse(rom)
            #expect(info.romBytes == SyntheticGBA.romSizes[Int(code)])
        }
    }

    @Test func everyRAMSizeCodeParses() throws {
        let sizes = [0, 2048, 8192, 32768, 131_072, 65_536]
        for (code, bytes) in sizes.enumerated() {
            let rom = SyntheticGBA.make(program: [0x00], ramSizeCode: UInt8(code))
            #expect(try GBACartridge.parse(rom).ramBytes == bytes)
        }
    }

    @Test func unknownRAMSizeCodeMeansNoSaveMemory() throws {
        // An unknown save size is not a reason to refuse the cartridge, it just means the
        // save media cannot be worked out.
        let rom = SyntheticGBA.make(program: [0x00], ramSizeCode: 99)
        #expect(try GBACartridge.parse(rom).ramBytes == 0)
    }

    @Test func headerOnlyROMHasTheSmallestSize() throws {
        // A file that stops at the header has no size codes: it claims the smallest cartridge.
        var rom = SyntheticGBA.make(program: [0x00])
        rom = Array(rom[0..<0xC0])
        let info = try GBACartridge.parse(rom)
        #expect(info.romBytes == 0x8000)
        #expect(info.ramBytes == 0)
    }

    @Test func complementCheckMatchesTheBIOSFormula() throws {
        // The BIOS wants 0xBD to be the complement of the sum of 0xA0..0xBC plus 19h.
        var rom = SyntheticGBA.make(program: [0x00], title: "CHECK")
        rom[0xBD] = 0
        var sum = 0
        for i in 0xA0...0xBC { sum += Int(rom[i]) }
        rom[0xBD] = UInt8(truncatingIfNeeded: -(0x19 + sum))
        #expect(try GBACartridge.parse(rom).title == "CHECK")
    }
}
