import EmuSupport
import EmulatorKit
import GBCore

/// Input source that never presses anything, or replays a scripted button state.
public final class ScriptedInput: InputSource {
    public var buttons: PadButtons = []
    public init() {}
    public func snapshot(port: Int) -> InputSnapshot {
        var s = InputSnapshot()
        s.buttons = buttons
        return s
    }
}

public final class NullOutput: OutputSink {
    public var lastRumble: Float = 0
    public init() {}
    public func setRumble(port: Int, low: Float, high: Float) { lastRumble = low }
}

public struct GBRunResult {
    public var frames: Int
    public var pixels: [UInt32] = []
    public var serial: String
    public var frameHash: UInt64
    public var passedByText: Bool?
}

/// Runs a Game Boy ROM headlessly for up to `maxFrames`, stopping early once serial output says Passed/Failed.
public enum HeadlessGB {
    public static func frameHash(_ core: GameBoyCore) -> UInt64 {
        let v = core.video
        return XXH64.hash(UnsafeRawBufferPointer(start: v.pixels, count: v.pitch * v.height))
    }

    public static func pixels(_ core: GameBoyCore) -> [UInt32] {
        let v = core.video
        return Array(UnsafeBufferPointer(start: v.pixels.assumingMemoryBound(to: UInt32.self), count: v.width * v.height))
    }

    public static func run(rom: [UInt8], maxFrames: Int, model: String = "auto",
                           stopOnSerialVerdict: Bool = true) throws -> GBRunResult {
        let core = try GameBoyCore(media: .rom(rom), firmware: FirmwareSet(), options: CoreOptions(values: ["model": model]),
                                   clock: FixedClock(seconds: 1_700_000_000))
        let input = ScriptedInput(), output = NullOutput()
        var frames = 0
        var verdict: Bool?
        while frames < maxFrames {
            core.runFrame(input: input, output: output)
            core.drainAudio { _ in }
            frames += 1
            // Newer Blargg tests also report through cartridge RAM: signature DE B0 61 at A001, status at A000.
            if core.peek(0xA001) == 0xDE && core.peek(0xA002) == 0xB0 && core.peek(0xA003) == 0x61 {
                let status = core.peek(0xA000)
                if status != 0x80 {
                    verdict = status == 0
                    var text = ""
                    var addr: UInt16 = 0xA004
                    while addr < 0xBFFF, core.peek(addr) != 0 { text.append(Character(UnicodeScalar(core.peek(addr)))); addr += 1 }
                    return GBRunResult(frames: frames, pixels: pixels(core), serial: text, frameHash: frameHash(core), passedByText: verdict)
                }
            }
            if stopOnSerialVerdict {
                let text = String(decoding: core.serialOutput, as: UTF8.self)
                if text.contains("Passed") { verdict = true; break }
                if text.contains("Failed") { verdict = false; break }
            }
        }
        return GBRunResult(frames: frames, pixels: pixels(core), serial: String(decoding: core.serialOutput, as: UTF8.self),
                           frameHash: frameHash(core), passedByText: verdict)
    }
}
