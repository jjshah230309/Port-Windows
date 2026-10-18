import ControllerModel
import EmuSupport
import EmulatorKit
import GBACore
import GBCore
import PS1Core

/// Framework-free checks. They run from `core-selftest` and from `Attic --self-test`, so they work even where
/// XCTest / swift-testing are unavailable (for example with only the Command Line Tools installed).
public enum SelfTest {
    /// Returns a list of failure descriptions; empty means everything passed.
    public static func run() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

        check(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926, "CRC32 check value")
        check(XXH64.hash([UInt8]()) == 0xEF46_DB37_51D8_E999, "XXH64 of empty input")

        var writer = StateWriter(system: "gb", gameHash: 0x1234)
        writer.chunk("CPU ", [1, 2, 3])
        if var reader = try? StateReader(bytes: writer.bytes), let chunk = try? reader.nextChunk() {
            check(reader.system == "gb" && reader.gameHash == 0x1234, "state header round trip")
            check(chunk.tag == "CPU " && chunk.payload == [1, 2, 3], "state chunk round trip")
        } else {
            failures.append("state codec could not read back its own output")
        }

        check(Deadzone.radial(SIMD2(0.05, 0.05), inner: 0.12, outer: 0.97) == .zero, "deadzone swallows small input")
        check(Deadzone.radial(SIMD2(1, 0), inner: 0.12, outer: 0.97).x == 1, "deadzone reaches full scale")

        let report = SonyReports.appendingCRC(seed: SonyReports.outputSeed, to: [0x31, 0x02, 0x10, 0x00])
        check(SonyReports.verifyCRC(seed: SonyReports.outputSeed, report: report), "Sony CRC accepts a good report")

        var trace = ControllerTrace()
        var frame = RawControllerState()
        frame.buttons = PadButtons([.south, .start]).rawValue
        frame.leftStick = SIMD2(0.5, -0.25)
        trace.frames = [frame]
        check((try? ControllerTrace.parse(trace.serialized())) == trace, "controller trace round trip")

        let infos = [GameBoy.info, GameBoyAdvance.info, PlayStation1.info]
        check(infos.allSatisfy { $0.framesPerSecond > 0 }, "system infos have a frame rate")
        return failures
    }
}
