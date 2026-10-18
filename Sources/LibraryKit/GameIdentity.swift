/// What the cartridge header says about a Game Boy ROM.
public struct GameHeader: Equatable, Sendable {
    public var title: String
    public var isColor: Bool          // CGB flag: colour-enhanced or colour-only
    public var cartridgeType: UInt8
    public var romBytes: Int
    public var headerChecksumValid: Bool
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

    /// True when the file plausibly is a Game Boy ROM: a header whose checksum matches, which the console itself requires.
    public static func looksLikeGameBoyROM(_ rom: [UInt8]) -> Bool {
        parseHeader(rom)?.headerChecksumValid ?? false
    }
}

extension String {
    fileprivate func trimmingTrailing() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
