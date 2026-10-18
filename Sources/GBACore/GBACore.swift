import EmulatorKit

/// Game Boy Advance core. Implemented in milestone M3.
public enum GameBoyAdvance {
    public static let info = SystemInfo(
        id: "gba", label: "32-bit handheld (.gba)", width: 240, height: 160,
        fpsNumerator: 16_777_216, fpsDenominator: 280_896, audioRate: 48_000)
}
