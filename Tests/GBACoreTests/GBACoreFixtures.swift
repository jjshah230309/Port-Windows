import EmulatorKit
import GBACore

/// A pad the core can read.
final class GBATestInput: InputSource {
    var buttons: PadButtons = []
    func snapshot(port: Int) -> InputSnapshot {
        var s = InputSnapshot()
        s.buttons = buttons
        return s
    }
}

/// A rumble sink the core can write to.
final class GBATestOutput: OutputSink {
    var rumble: [(port: Int, low: Float, high: Float)] = []
    func setRumble(port: Int, low: Float, high: Float) { rumble.append((port, low, high)) }
}

extension GameBoyAdvanceCore {
    /// Builds a core around a synthetic ROM.
    static func core(_ rom: [UInt8], firmware: FirmwareSet = FirmwareSet()) throws -> GameBoyAdvanceCore {
        try GameBoyAdvanceCore(media: .rom(rom), firmware: firmware, options: CoreOptions(),
                                clock: FixedClock(seconds: 1_700_000_000))
    }
}
