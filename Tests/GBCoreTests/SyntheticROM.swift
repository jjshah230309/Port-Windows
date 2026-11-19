import EmulatorKit
import GBCore

/// Builds tiny Game Boy ROMs from hand-assembled machine code so core tests need no external files.
enum SyntheticROM {
    /// `program` is placed at 0x0150; `at` places extra bytes (such as interrupt handlers) at fixed addresses.
    static func make(program: [UInt8], cartType: UInt8 = 0x00, banks: Int = 2, ramCode: UInt8 = 0,
                     cgb: Bool = false, at extra: [Int: [UInt8]] = [:]) -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: banks * 0x4000)
        rom[0x100] = 0x00; rom[0x101] = 0xC3; rom[0x102] = 0x50; rom[0x103] = 0x01     // NOP; JP $0150
        for (i, c) in "SYNTH".utf8.enumerated() { rom[0x134 + i] = c }
        rom[0x143] = cgb ? 0x80 : 0x00
        rom[0x147] = cartType
        var code: UInt8 = 0
        while (0x8000 << Int(code)) < banks * 0x4000 { code += 1 }
        rom[0x148] = code
        rom[0x149] = ramCode
        for (i, b) in program.enumerated() { rom[0x150 + i] = b }
        for (addr, bytes) in extra { for (i, b) in bytes.enumerated() { rom[addr + i] = b } }
        return rom
    }

    /// LD A,byte; LDH (SB),A; LD A,$81; LDH (SC),A; wait for the transfer to finish.
    static func sendSerial(_ byte: UInt8) -> [UInt8] {
        [0x3E, byte, 0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02, 0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA]
    }

    /// LD A,n ; LD (addr),A
    static func store(_ value: UInt8, at addr: UInt16) -> [UInt8] {
        [0x3E, value, 0xEA, UInt8(addr & 0xFF), UInt8(addr >> 8)]
    }

    static let spin: [UInt8] = [0x18, 0xFE]     // JR -2

    static func core(_ rom: [UInt8], model: String = "auto", clock: any HostClock = FixedClock(seconds: 1_700_000_000)) throws -> GameBoyCore {
        try GameBoyCore(media: .rom(rom), firmware: FirmwareSet(), options: CoreOptions(values: ["model": model]), clock: clock)
    }
}

final class TestInput: InputSource {
    var buttons: PadButtons = []
    func snapshot(port: Int) -> InputSnapshot {
        var s = InputSnapshot()
        s.buttons = buttons
        return s
    }
}

final class TestOutput: OutputSink {
    var rumble: [Float] = []
    func setRumble(port: Int, low: Float, high: Float) { rumble.append(low) }
}

extension GameBoyCore {
    func run(frames: Int, input: TestInput = TestInput(), output: TestOutput = TestOutput()) {
        for _ in 0..<frames {
            runFrame(input: input, output: output)
            drainAudio { _ in }
        }
    }
}
