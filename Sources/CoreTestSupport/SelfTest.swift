import ControllerModel
import EmuSupport
import EmulatorKit
import GBACore
import GBCore
import PS1Core

/// Framework-free checks. They run from `core-selftest` and from `Attic --self-test`, so they work even where
/// XCTest / swift-testing are unavailable (for example with only the Command Line Tools installed).
public enum SelfTest {
    /// One named check. The body returns nil when the check passes, or a description of what was
    /// expected and what was seen.
    public struct Check: Sendable {
        public let name: String
        public let body: @Sendable () -> String?

        public init(name: String, body: @escaping @Sendable () -> String?) {
            self.name = name
            self.body = body
        }
    }

    // MARK: - Running the checks

    /// The checks the self-test runs. A caller that wants a different set - a test adding a
    /// deliberately failing check, say - passes its own list to `run(checks:)`.
    public static var checks: [Check] { standard }

    /// Runs every check and returns the failures; an empty list means everything passed.
    public static func run() -> [String] { run(checks: standard) }

    /// Runs the given checks and returns one message per failure.
    public static func run(checks: [Check]) -> [String] {
        var failures: [String] = []
        for check in checks {
            if let failure = check.body() { failures.append("\(check.name): \(failure)") }
        }
        return failures
    }

    // MARK: - The checks

    private static let standard: [Check] = pureChecks + gameBoyChecks + gameBoyAdvanceChecks + inputChecks

    private static let pureChecks: [Check] = [
        Check(name: "CRC32 check value") {
            let got = CRC32.checksum(Array("123456789".utf8))
            return got == 0xCBF4_3926 ? nil : "expected 0xCBF43926, saw \(hex(UInt64(got)))"
        },
        Check(name: "XXH64 of empty input") {
            let got = XXH64.hash([UInt8]())
            return got == 0xEF46_DB37_51D8_E999 ? nil : "expected 0xef46db3751d8e999, saw \(hex(got))"
        },
        Check(name: "state codec round trip") {
            var writer = StateWriter(system: "gb", gameHash: 0x1234)
            writer.chunk("CPU ", [1, 2, 3])
            guard var reader = try? StateReader(bytes: writer.bytes), let chunk = try? reader.nextChunk() else {
                return "could not read back the bytes the writer had just produced"
            }
            if reader.system != "gb" || reader.gameHash != 0x1234 {
                return "expected system \"gb\" and game hash 0x1234, saw \"\(reader.system)\" and \(hex(reader.gameHash))"
            }
            if chunk.tag != "CPU " || chunk.payload != [1, 2, 3] {
                return "expected the chunk \"CPU \" with payload [1, 2, 3], saw \"\(chunk.tag)\" with \(chunk.payload)"
            }
            return nil
        },
        Check(name: "deadzone swallows small input") {
            let got = Deadzone.radial(SIMD2(0.05, 0.05), inner: 0.12, outer: 0.97)
            return got == .zero ? nil : "expected zero, saw (\(got.x), \(got.y))"
        },
        Check(name: "deadzone reaches full scale") {
            let got = Deadzone.radial(SIMD2(1, 0), inner: 0.12, outer: 0.97)
            return got.x == 1 && got.y == 0 ? nil : "expected (1, 0), saw (\(got.x), \(got.y))"
        },
        Check(name: "Sony CRC accepts a good report") {
            let report = SonyReports.appendingCRC(seed: SonyReports.outputSeed, to: [0x31, 0x02, 0x10, 0x00])
            return SonyReports.verifyCRC(seed: SonyReports.outputSeed, report: report)
                ? nil : "expected the appended CRC to verify, saw a mismatch"
        },
        Check(name: "Sony CRC rejects a corrupted report") {
            var report = SonyReports.appendingCRC(seed: SonyReports.outputSeed, to: [0x31, 0x02, 0x10, 0x00])
            report[0] ^= 0x01
            return SonyReports.verifyCRC(seed: SonyReports.outputSeed, report: report)
                ? "expected a corrupted report to be rejected, saw it accepted" : nil
        },
        Check(name: "controller trace round trip") {
            var trace = ControllerTrace()
            var frame = RawControllerState()
            frame.buttons = PadButtons([.south, .start]).rawValue
            frame.leftStick = SIMD2(0.5, -0.25)
            trace.frames = [frame]
            do {
                let parsed = try ControllerTrace.parse(trace.serialized())
                return parsed == trace ? nil : "expected \(trace), saw \(parsed)"
            } catch {
                return "could not parse the trace it had just written: \(error)"
            }
        },
        Check(name: "system infos have a frame rate") {
            for info in [GameBoyCore.info, GameBoyAdvance.info, PlayStation1.info] where info.framesPerSecond <= 0 {
                return "expected \(info.id) to run faster than zero frames a second, saw \(info.framesPerSecond)"
            }
            return nil
        },
    ]

    private static let gameBoyChecks: [Check] = [
        Check(name: "Game Boy core runs a synthetic ROM") {
            do {
                let core = try gameBoyCore(gameBoyROM())
                var samples = 0
                var audible = 0
                for _ in 0..<60 {
                    core.runFrame(input: ScriptedInput(), output: NullOutput())
                    core.drainAudio { buffer in
                        samples += buffer.count
                        for sample in buffer where sample != 0 { audible += 1 }
                    }
                }
                let colours = Set(HeadlessGB.pixels(core))
                if colours.count <= 1 {
                    return "expected more than one colour in the frame buffer, saw \(describeColours(colours))"
                }
                if audible == 0 {
                    return "expected audio that is not silent, saw \(samples) samples and every one of them zero"
                }
                return nil
            } catch {
                return "the core could not be built: \(error)"
            }
        },
        Check(name: "Game Boy core is deterministic") {
            do {
                let first = try gameBoyFrameHash(frames: 60)
                let second = try gameBoyFrameHash(frames: 60)
                return first == second ? nil
                    : "expected both runs to end on the same frame hash, saw \(hex(first)) and \(hex(second))"
            } catch {
                return "the core could not be built: \(error)"
            }
        },
        Check(name: "Game Boy save state round trips through the core") {
            do {
                let rom = gameBoyROM()
                let straight = try gameBoyCore(rom)
                run(straight, frames: 30)
                let earlyHash = HeadlessGB.frameHash(straight)
                run(straight, frames: 30)
                let straightHash = HeadlessGB.frameHash(straight)

                // The frame has to change from one frame to the next, or the comparison below
                // would pass even if the state had been thrown away and the machine restarted.
                if earlyHash == straightHash {
                    return "expected the frame to change between frames 30 and 60, saw the same hash \(hex(straightHash))"
                }

                let replay = try gameBoyCore(rom)
                run(replay, frames: 30)
                var writer = StateWriter(system: "gb", gameHash: XXH64.hash(rom))
                replay.saveState(into: &writer)
                run(replay, frames: 30)
                var reader = try StateReader(bytes: writer.bytes)
                try replay.loadState(from: &reader)
                run(replay, frames: 30)
                let replayHash = HeadlessGB.frameHash(replay)

                return straightHash == replayHash ? nil
                    : "expected the run that never saved to end on \(hex(straightHash)), saw \(hex(replayHash))"
            } catch {
                return "the state could not be written or read back: \(error)"
            }
        },
    ]

    private static let gameBoyAdvanceChecks: [Check] = [
        Check(name: "Game Boy Advance core runs a frame") {
            do {
                let core = try GameBoyAdvanceCore(media: .rom(gameBoyAdvanceROM()), firmware: FirmwareSet(),
                                                  options: CoreOptions(), clock: FixedClock(seconds: 1_700_000_000))
                core.runFrame(input: ScriptedInput(), output: NullOutput())
                core.drainAudio { _ in }
                let v = core.video
                if v.width != 240 || v.height != 160 || v.pitch != 240 * 4 {
                    return "expected a 240 x 160 frame with a pitch of 960, saw \(v.width) x \(v.height) with a pitch of \(v.pitch)"
                }
                if v.format != .bgra8 {
                    return "expected the bgra8 pixel format, saw \(v.format)"
                }
                // Reading both ends proves the buffer is there and not just a pointer to nothing.
                let pixels = UnsafeRawBufferPointer(start: v.pixels, count: v.pitch * v.height)
                _ = pixels.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                _ = pixels.loadUnaligned(fromByteOffset: pixels.count - 4, as: UInt32.self)
                return nil
            } catch {
                return "the core could not be built: \(error)"
            }
        },
    ]

    private static let inputChecks: [Check] = [
        Check(name: "turbo button is pressed on some frames and not on others") {
            var pipeline = InputPipeline()
            pipeline.turbo[.south] = TurboSetting(period: 4)
            var raw = RawControllerState()
            raw.buttons = PadButtons([.south]).rawValue
            var pressed: [Int] = []
            var released: [Int] = []
            for frame in 0..<8 {
                let out = pipeline.process(raw, frame: frame)
                if out.buttons.contains(.south) { pressed.append(frame) } else { released.append(frame) }
            }
            if pressed.isEmpty {
                return "expected the turbo button down on some of frames 0..<8, saw it up on all of them"
            }
            if released.isEmpty {
                return "expected the turbo button up on some of frames 0..<8, saw it down on all of them"
            }
            return nil
        },
        Check(name: "a stick past the d-pad gate produces a direction") {
            var pipeline = InputPipeline()
            pipeline.stickAsDPad = true
            pipeline.stickAsDPadGate = 0.5
            var raw = RawControllerState()
            raw.leftStick = SIMD2(1, 0)
            let out = pipeline.process(raw, frame: 0)
            guard out.buttons.contains(.right) else {
                return "expected the d-pad to report right, saw \(out.buttons.rawValue)"
            }
            return nil
        },
        Check(name: "a stick inside the d-pad gate produces no direction") {
            var pipeline = InputPipeline()
            pipeline.stickAsDPad = true
            pipeline.stickAsDPadGate = 0.5
            var raw = RawControllerState()
            raw.leftStick = SIMD2(0.2, 0)
            let out = pipeline.process(raw, frame: 0)
            return out.buttons.isEmpty ? nil
                : "expected no d-pad direction below the gate, saw \(out.buttons.rawValue)"
        },
    ]

    // MARK: - Synthetic ROMs

    /// A Game Boy ROM that switches the sound on, writes a patterned tile into VRAM, scrolls the
    /// background one pixel per VBlank and then spins.
    ///
    /// The tile makes the frame buffer more than one colour, the sound channel makes the audio
    /// buffer non-zero, and the scroll makes the frame change from one frame to the next, so a
    /// save state that lost the machine's state would show up as a different frame.
    private static func gameBoyROM() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: 0x8000)
        rom[0x100] = 0x00; rom[0x101] = 0xC3; rom[0x102] = 0x50; rom[0x103] = 0x01     // NOP; JP $0150
        for (i, c) in "SYNTH".utf8.enumerated() { rom[0x134 + i] = c }
        rom[0x143] = 0x00                                                              // not a colour cartridge
        rom[0x147] = 0x00                                                              // no mapper
        rom[0x148] = 0x00                                                              // 32 KiB
        rom[0x149] = 0x00                                                              // no cartridge RAM
        for (i, b) in gameBoyProgram().enumerated() { rom[0x150 + i] = b }
        // The VBlank handler scrolls the background and returns.
        let vblank: [UInt8] = [
            0xF0, 0x43,                       // LDH A,($43) - SCX
            0x3C,                            // INC A
            0xE0, 0x43,                       // LDH ($43),A
            0xD9,                            // RETI
        ]
        for (i, b) in vblank.enumerated() { rom[0x40 + i] = b }
        return rom
    }

    private static func gameBoyProgram() -> [UInt8] {
        var p: [UInt8] = []
        p += [0x3E, 0x00, 0xE0, 0x40]                                                  // LD A,$00; LDH ($40),A - LCD off
        p += [0x3E, 0x80, 0xE0, 0x26]                                                  // LD A,$80; LDH ($26),A - sound on
        p += [0x3E, 0x77, 0xE0, 0x24]                                                  // LD A,$77; LDH ($24),A - volume
        p += [0x3E, 0xFF, 0xE0, 0x25]                                                  // LD A,$FF; LDH ($25),A - panning
        p += [0x3E, 0xFB, 0xE0, 0x12]                                                  // LD A,$FB; LDH ($12),A - channel 1 envelope
        p += [0x3E, 0x80, 0xE0, 0x10]                                                  // LD A,$80; LDH ($10),A - channel 1 sweep
        p += [0x3E, 0xBF, 0xE0, 0x11]                                                  // LD A,$BF; LDH ($11),A - channel 1 duty
        p += [0x3E, 0x00, 0xE0, 0x13]                                                  // LD A,$00; LDH ($13),A - channel 1 frequency
        p += [0x3E, 0x87, 0xE0, 0x14]                                                  // LD A,$87; LDH ($14),A - channel 1 trigger
        p += [0x21, 0x00, 0x80]                                                        // LD HL,$8000
        p += [0x06, 0x10]                                                              // LD B,$10
        p += [0x78, 0xEE, 0x5A, 0x22, 0x05]                                            // LD A,B; XOR $5A; LD (HL+),A; DEC B
        p += [0x20, 0xF9]                                                              // JR NZ,-7
        p += [0x3E, 0xE4, 0xE0, 0x47]                                                  // LD A,$E4; LDH ($47),A - BGP
        p += [0x3E, 0x01, 0xE0, 0xFF]                                                  // LD A,$01; LDH ($FF),A - IE, VBlank
        p += [0x3E, 0x91, 0xE0, 0x40]                                                  // LD A,$91; LDH ($40),A - LCD on, background on
        p += [0xFB]                                                                    // EI
        p += [0x18, 0xFE]                                                              // JR -2
        return p
    }

    /// A Game Boy Advance cartridge: the header the BIOS checks, a branch to the program and a
    /// program that only branches to itself, because the core has no CPU yet.
    private static func gameBoyAdvanceROM() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: 0x8000)
        rom[0x00] = 0xEA; rom[0x01] = 0x00; rom[0x02] = 0x00; rom[0x03] = 0x3B         // B $C0
        for (i, c) in "SYNTH".utf8.enumerated() { rom[0xA0 + i] = c }
        for (i, c) in "ATSE".utf8.enumerated() { rom[0xAC + i] = c }
        for (i, c) in "01".utf8.enumerated() { rom[0xB0 + i] = c }
        rom[0xB2] = 0x96                                                               // the fixed value
        rom[0xC0] = 0xEA; rom[0xC1] = 0xFF; rom[0xC2] = 0xFF; rom[0xC3] = 0xFE         // B .
        rom[0xE0] = 0x00                                                               // 32 KiB
        var sum = 0
        for i in 0xA0...0xBC { sum += Int(rom[i]) }
        rom[0xBD] = UInt8(truncatingIfNeeded: -(0x19 + sum))                           // the complement check
        return rom
    }

    // MARK: - Helpers

    private static func gameBoyCore(_ rom: [UInt8]) throws -> GameBoyCore {
        try GameBoyCore(media: .rom(rom), firmware: FirmwareSet(),
                         options: CoreOptions(values: ["model": "auto"]),
                         clock: FixedClock(seconds: 1_700_000_000))
    }

    private static func run(_ core: GameBoyCore, frames: Int) {
        let input = ScriptedInput(), output = NullOutput()
        for _ in 0..<frames {
            core.runFrame(input: input, output: output)
            core.drainAudio { _ in }
        }
    }

    private static func gameBoyFrameHash(frames: Int) throws -> UInt64 {
        let core = try gameBoyCore(gameBoyROM())
        run(core, frames: frames)
        return HeadlessGB.frameHash(core)
    }

    private static func describeColours(_ colours: Set<UInt32>) -> String {
        let sorted = colours.sorted()
        let shown = sorted.prefix(4).map { hex(UInt64($0)) }.joined(separator: ", ")
        return sorted.count > 4 ? "\(sorted.count) distinct colours (\(shown), ...)"
                                : "\(sorted.count) distinct colours (\(shown))"
    }

    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
}
