/// What the cartridge header says about a Game Boy ROM.
public struct GameHeader: Equatable, Sendable {
    public var title: String
    public var isColor: Bool          // CGB flag: colour-enhanced or colour-only
    public var cartridgeType: UInt8
    public var romBytes: Int
    public var headerChecksumValid: Bool
}

/// What the cartridge header says about a Game Boy Advance ROM.
public struct GBAHeader: Equatable, Sendable {
    public var title: String
    public var gameCode: String
    public var makerCode: String
    public var romBytes: Int
    public var complementCheckValid: Bool
}

/// A ROM that has been matched to the system it belongs to.
public struct IdentifiedGame: Equatable, Sendable {
    public var system: LibrarySystem
    public var title: String
    public var isColor: Bool
}

public enum GameIdentity {
    /// Parses the header at 0x100...0x14F. Returns nil when the file is too small to hold one.
    public static func parseHeader(_ rom: [UInt8]) -> GameHeader? {
        guard rom.count >= 0x150 else { return nil }
        let flag = rom[0x143]
        let isColor = flag == 0x80 || flag == 0xC0
        let titleEnd = isColor ? 0x13F : 0x144
        let title = String(decoding: rom[0x134..<titleEnd].prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingTrailing()
        var checksum: UInt8 = 0
        for i in 0x134...0x14C { checksum = checksum &- rom[i] &- 1 }
        return GameHeader(title: title, isColor: isColor, cartridgeType: rom[0x147], romBytes: rom.count,
                          headerChecksumValid: checksum == rom[0x14D])
    }

    /// Parses the Game Boy Advance header at 0x00...0xBF. Returns nil when the file is too small to hold one.
    public static func parseGBAHeader(_ rom: [UInt8]) -> GBAHeader? {
        guard rom.count >= 0xC0 else { return nil }
        var sum: UInt8 = 0
        for i in 0xA0...0xBC { sum = sum &+ rom[i] }
        let title = String(decoding: rom[0xA0..<0xAC].prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingTrailing()
        let gameCode = String(decoding: rom[0xAC..<0xB0].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingTrailing()
        let makerCode = String(decoding: rom[0xB0..<0xB2].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingTrailing()
        // The BIOS expects 0xBD to be the complement of the sum of 0xA0...0xBC plus 0x19, which
        // is what a real cartridge carries. Getting this wrong rejects every genuine ROM.
        let expected = UInt8(truncatingIfNeeded: -(0x19 + Int(sum)))
        return GBAHeader(title: title, gameCode: gameCode, makerCode: makerCode, romBytes: rom.count,
                         complementCheckValid: rom[0xBD] == expected)
    }

    /// True when the file plausibly is a Game Boy ROM: a header whose checksum matches, which the console itself requires.
    public static func looksLikeGameBoyROM(_ rom: [UInt8]) -> Bool {
        parseHeader(rom)?.headerChecksumValid ?? false
    }

    /// True when the file plausibly is a Game Boy Advance ROM: a header whose complement check matches.
    public static func looksLikeGBAROM(_ rom: [UInt8]) -> Bool {
        parseGBAHeader(rom)?.complementCheckValid ?? false
    }

    /// Reads the header of a ROM of the given system. Returns nil when the file fails that system's own check.
    public static func identify(_ rom: [UInt8], for system: LibrarySystem) -> IdentifiedGame? {
        switch system {
        case .gameBoy:
            guard let header = parseHeader(rom), header.headerChecksumValid else { return nil }
            return IdentifiedGame(system: system, title: header.title, isColor: header.isColor)
        case .gameBoyAdvance:
            guard let header = parseGBAHeader(rom), header.complementCheckValid else { return nil }
            // The CGB flag means nothing here: every GBA cartridge is colour.
            return IdentifiedGame(system: system, title: header.title, isColor: false)
        }
    }

    /// Matches a ROM to the system it belongs to. `preferred` is the system the file extension claims;
    /// when that check fails the other systems are tried, so a misnamed file still works.
    public static func identify(_ rom: [UInt8], preferred: LibrarySystem?) -> IdentifiedGame? {
        var order = LibrarySystem.allCases
        if let preferred, let i = order.firstIndex(of: preferred) {
            order.remove(at: i)
            order.insert(preferred, at: 0)
        }
        for system in order {
            if let game = identify(rom, for: system) { return game }
        }
        return nil
    }
}

extension String {
    fileprivate func trimmingTrailing() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
