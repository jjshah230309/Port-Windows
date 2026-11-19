import GBACore

/// Builds tiny Game Boy Advance ROMs from hand-assembled machine code so cartridge tests need no external files.
///
/// The header is the one a real cartridge carries: the fixed value at 0xB2, the complement check
/// at 0xBD and the size codes at 0xE0 and 0xE2. The Nintendo logo at 0x04..0x9F is left zero
/// filled - the BIOS compares it, but the cartridge layer does not, so a test ROM does not need
/// 156 bytes of compressed bitmap to be a valid cartridge.
enum SyntheticGBA {
    /// The ROM sizes in bytes, indexed by the size code the header carries at 0xE0.
    static let romSizes = [0x8000, 0x10000, 0x20000, 0x40000, 0x80000, 0x100000,
                            0x200000, 0x400000, 0x800000, 0x1000000, 0x2000000]

    /// `program` is placed at 0xC0, just past the header; `at` places extra bytes at fixed addresses.
    ///
    /// The complement check is computed correctly, so the ROM is one the BIOS would boot, unless
    /// `breakComplement` says otherwise. `fileBytes` overrides the length of the file, which
    /// lets a test hand the parser a file that is a different size from the one it claims.
    static func make(program: [UInt8], title: String = "SYNTH", gameCode: String = "ATSE",
                     makerCode: String = "01", romSizeCode: UInt8 = 0, ramSizeCode: UInt8 = 0,
                     destinationCode: UInt8 = 0, developerID: UInt8 = 0, version: UInt16 = 0,
                     fixedValue: UInt8 = 0x96, breakComplement: Bool = false,
                     fileBytes: Int? = nil, at extra: [Int: [UInt8]] = [:]) -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: fileBytes ?? romLength(romSizeCode))
        rom[0x00] = 0xEA; rom[0x01] = 0x00; rom[0x02] = 0x00; rom[0x03] = 0x3B     // B $C0
        for (i, c) in title.utf8.enumerated() { rom[0xA0 + i] = c }
        for (i, c) in gameCode.utf8.enumerated() { rom[0xAC + i] = c }
        for (i, c) in makerCode.utf8.enumerated() { rom[0xB0 + i] = c }
        rom[0xB2] = fixedValue
        for (i, b) in program.enumerated() { rom[0xC0 + i] = b }
        for (addr, bytes) in extra { for (i, b) in bytes.enumerated() { rom[addr + i] = b } }
        rom[0xE0] = romSizeCode
        rom[0xE1] = destinationCode
        rom[0xE2] = ramSizeCode
        rom[0xE3] = developerID
        rom[0xE4] = UInt8(truncatingIfNeeded: version)
        rom[0xE5] = UInt8(truncatingIfNeeded: version >> 8)

        // The complement check covers 0xA0..0xBC and is the last byte the BIOS sums.
        fixComplement(&rom)
        if breakComplement { rom[0xBD] ^= 0xFF }
        return rom
    }

    /// Recomputes the complement check at 0xBD, for a ROM whose header bytes have been changed.
    static func fixComplement(_ rom: inout [UInt8]) {
        var sum = 0
        for i in 0xA0...0xBC { sum += Int(rom[i]) }
        rom[0xBD] = UInt8(truncatingIfNeeded: -(0x19 + sum))
    }

    /// The length of a ROM carrying the given size code. An unknown code has no size, so the
    /// smallest cartridge is built and the unknown code is left in the header for the parser
    /// to reject.
    private static func romLength(_ code: UInt8) -> Int {
        Int(code) < romSizes.count ? romSizes[Int(code)] : romSizes[0]
    }
}
