// The Game Boy Advance cartridge layer: the header, the sizes it describes, and the checks the
// BIOS makes on a cartridge it is willing to boot.
//
// The header is the 192 bytes at 0x00..0xBF (GBATEK, "GBA Cartridge Header"):
//
//   0x00        entry point, a 32bit ARM branch
//   0x04..0x9F  Nintendo logo, 156 bytes of compressed bitmap
//   0xA0..0xAB  game title, 12 bytes, zero padded
//   0xAC..0xAF  game code, 4 characters
//   0xB0..0xB1  maker code, 2 characters
//   0xB2        fixed value, 96h
//   0xB3        main unit code
//   0xB4        device type
//   0xB5..0xBB  reserved
//   0xBC        software version
//   0xBD        complement check
//   0xBE..0xBF  reserved
//
// The size bytes at 0xE0..0xE5 are not part of Nintendo's header - on hardware 0xE0 holds the
// JOYBUS entry point - but they are the de-facto convention of the homebrew and flashcart
// tooling, and they are the only place a GBA ROM states its own size:
//
//   0xE0        ROM size code
//   0xE1        destination code
//   0xE2        RAM size code
//   0xE3        developer id
//   0xE4..0xE5  version, little endian
//
// A GBA cartridge has no mapper and no banking: the whole ROM sits in one window at 0x08000000,
// so this layer is the header, the sizes and the checks, nothing else.

/// What a Game Boy Advance cartridge says about itself.
public struct GBACartridgeInfo: Equatable, Sendable {
    /// Title, from the 12 bytes at 0xA0, trimmed of padding and unprintable bytes.
    public var title: String
    /// Game code, 4 characters from 0xAC.
    public var gameCode: String
    /// Maker code, 2 characters from 0xB0.
    public var makerCode: String
    /// ROM size in bytes, from the size code at 0xE0. This is the size the cartridge claims to
    /// be, not the length of the file that holds it.
    public var romBytes: Int
    /// Save RAM size in bytes, from the size code at 0xE2.
    public var ramBytes: Int
    /// Destination code, from 0xE1.
    public var destinationCode: UInt8
    /// Developer id, from 0xE3.
    public var developerID: UInt8
    /// Version, the two bytes at 0xE4, little endian.
    public var version: UInt16

    public init(title: String, gameCode: String, makerCode: String, romBytes: Int, ramBytes: Int,
                destinationCode: UInt8 = 0, developerID: UInt8 = 0, version: UInt16 = 0) {
        self.title = title
        self.gameCode = gameCode
        self.makerCode = makerCode
        self.romBytes = romBytes
        self.ramBytes = ramBytes
        self.destinationCode = destinationCode
        self.developerID = developerID
        self.version = version
    }
}

/// Why a cartridge could not be used.
public enum GBACartridgeError: Error, Equatable {
    /// The file is not a cartridge image at all: it is too small to hold a header.
    case invalidROM(String)
    /// The file is a cartridge image, but not one the machine will run.
    case unsupportedROM(String)
}

/// Reads the header of a Game Boy Advance cartridge.
public enum GBACartridge {
    /// The size of the cartridge header, 0x00..0xBF.
    public static let headerBytes = 0xC0

    /// ROM sizes in bytes, indexed by the size code at 0xE0.
    ///
    /// The size code counts 16 KiB units in the tools that write it, but a byte cannot hold the
    /// count of a real GBA ROM that way - 32 MiB would need 2048 - so the table steps in powers
    /// of two instead: code 0 is 32 KiB, code 1 is 64 KiB, and code 10 is the 32 MiB the
    /// cartridge bus can address. A code past the end of the table names a size that does not
    /// exist, and the ROM is rejected.
    static let romSizes = [0x8000, 0x10000, 0x20000, 0x40000, 0x80000, 0x100000,
                            0x200000, 0x400000, 0x800000, 0x1000000, 0x2000000]

    /// RAM sizes in bytes, indexed by the size code at 0xE2.
    static let ramSizes = [0, 2048, 8192, 32768, 131_072, 65_536]

    /// Reads the header of a cartridge, and rejects a ROM the machine would not boot.
    ///
    /// - Throws: `GBACartridgeError.invalidROM` when the file is smaller than the header, and
    ///   `GBACartridgeError.unsupportedROM` when the header fails one of the checks the BIOS
    ///   makes.
    public static func parse(_ rom: [UInt8]) throws -> GBACartridgeInfo {
        guard rom.count >= headerBytes else {
            throw GBACartridgeError.invalidROM("file is smaller than a cartridge header")
        }

        // The fixed value at 0xB2 must be 96h. The BIOS checks it, so a cartridge without it
        // locks the console up rather than starting a game. ENFORCED: a ROM that fails here is
        // not one the machine will run, and there is no reason to pretend otherwise.
        guard rom[0xB2] == 0x96 else {
            throw GBACartridgeError.unsupportedROM("fixed value at 0xB2 is not 96h")
        }

        // The complement check: the BIOS wants 0xBD to be the complement of the sum of
        // 0xA0..0xBC plus 19h, and locks up when it is wrong.
        var sum = 0
        for i in 0xA0...0xBC { sum += Int(rom[i]) }
        let expected = UInt8(truncatingIfNeeded: -(0x19 + sum))
        guard rom[0xBD] == expected else {
            throw GBACartridgeError.unsupportedROM("complement check at 0xBD does not match the header")
        }

        // The size codes live past the header, so a file that stops at 0xC0 has none: it claims
        // the smallest ROM and no RAM.
        let romCode = rom.count > 0xE0 ? Int(rom[0xE0]) : 0
        guard romCode < romSizes.count else {
            throw GBACartridgeError.unsupportedROM("unknown ROM size code \(romCode) at 0xE0")
        }
        // An unknown RAM size code means a cartridge whose save memory cannot be worked out;
        // it is treated as a cartridge with no save memory rather than a ROM that is refused.
        let ramCode = rom.count > 0xE2 ? Int(rom[0xE2]) : 0
        let ramBytes = ramCode < ramSizes.count ? ramSizes[ramCode] : 0

        let version = rom.count > 0xE5
            ? UInt16(rom[0xE4]) | UInt16(rom[0xE5]) << 8
            : 0

        return GBACartridgeInfo(
            title: text(rom, 0xA0, 12),
            gameCode: text(rom, 0xAC, 4),
            makerCode: text(rom, 0xB0, 2),
            romBytes: romSizes[romCode],
            ramBytes: ramBytes,
            destinationCode: rom.count > 0xE1 ? rom[0xE1] : 0,
            developerID: rom.count > 0xE3 ? rom[0xE3] : 0,
            version: version)
    }

    /// Reads a fixed-width ASCII field, dropping the zero padding and anything unprintable.
    ///
    /// The field stops at the first zero byte, so a title that is padded in the middle loses
    /// everything from the padding on, then the unprintable bytes are dropped and the trailing
    /// spaces are trimmed.
    static func text(_ rom: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard rom.count > offset else { return "" }
        let end = min(offset + length, rom.count)
        var s = ""
        for b in rom[offset..<end] {
            if b == 0 { break }
            guard b >= 0x20, b < 0x7F else { continue }
            s.append(Character(UnicodeScalar(b)))
        }
        while s.last == " " { s.removeLast() }
        return s
    }
}

extension GBACartridgeInfo {
    /// A best-effort reading of a cartridge, for callers that only want to show what a file
    /// claims to be: the checks are skipped, a file too small for a header gives empty fields,
    /// and a size code that is not in the table gives no ROM and no RAM.
    ///
    /// Use `GBACartridge.parse` to refuse a ROM the machine would not boot.
    public init(rom: [UInt8]) {
        let romCode = rom.count > 0xE0 ? Int(rom[0xE0]) : 0
        let ramCode = rom.count > 0xE2 ? Int(rom[0xE2]) : 0
        self.init(title: GBACartridge.text(rom, 0xA0, 12),
                  gameCode: GBACartridge.text(rom, 0xAC, 4),
                  makerCode: GBACartridge.text(rom, 0xB0, 2),
                  romBytes: romCode < GBACartridge.romSizes.count ? GBACartridge.romSizes[romCode] : 0,
                  ramBytes: ramCode < GBACartridge.ramSizes.count ? GBACartridge.ramSizes[ramCode] : 0,
                  destinationCode: rom.count > 0xE1 ? rom[0xE1] : 0,
                  developerID: rom.count > 0xE3 ? rom[0xE3] : 0,
                  version: rom.count > 0xE5 ? UInt16(rom[0xE4]) | UInt16(rom[0xE5]) << 8 : 0)
    }
}
