import EmulatorKit

/// PlayStation 1 core. Implemented in milestone M6.
public enum PlayStation1 {
    public static let info = SystemInfo(
        id: "ps1", label: "32-bit disc console (.cue / .chd)", width: 320, height: 240,
        fpsNumerator: 60, fpsDenominator: 1, audioRate: 44_100, padPorts: 8)
}
