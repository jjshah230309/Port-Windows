import EmuSupport

/// Checksums for DualShock 4 and DualSense reports sent over Bluetooth.
/// The CRC32 covers a one-byte seed followed by the report, with the result stored little-endian in the last 4 bytes.
public enum SonyReports {
    public static let inputSeed: UInt8 = 0xA1
    public static let outputSeed: UInt8 = 0xA2
    public static let featureSeed: UInt8 = 0xA3

    public static func crc(seed: UInt8, payload: ArraySlice<UInt8>) -> UInt32 {
        var c = CRC32()
        c.update([seed])
        c.update(payload)
        return c.value
    }

    /// Returns `report` with its 4-byte CRC appended. `report` must not already include the CRC.
    public static func appendingCRC(seed: UInt8, to report: [UInt8]) -> [UInt8] {
        let crc = crc(seed: seed, payload: report[...])
        var out = report
        for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i)))) }
        return out
    }

    /// True when the last 4 bytes of `report` are the correct CRC of everything before them.
    public static func verifyCRC(seed: UInt8, report: [UInt8]) -> Bool {
        guard report.count > 4 else { return false }
        let body = report[0..<(report.count - 4)]
        let expected = crc(seed: seed, payload: body)
        var stored: UInt32 = 0
        for i in 0..<4 { stored |= UInt32(report[report.count - 4 + i]) << (8 * UInt32(i)) }
        return stored == expected
    }
}
