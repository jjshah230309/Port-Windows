import EmulatorKit

/// Game Boy / Game Boy Color core. Implemented in milestone M1.
public enum GameBoy {
    public static let info = SystemInfo(
        id: "gb", label: "8-bit handheld (.gb / .gbc)", width: 160, height: 144,
        fpsNumerator: 4_194_304, fpsDenominator: 70_224, audioRate: 48_000)
}
