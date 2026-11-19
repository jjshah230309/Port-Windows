import Testing
import EmulatorKit
import EmuSupport
@testable import GBCore

@Suite struct CoreBehaviourTests {
    @Test func serialOutputIsCaptured() throws {
        let program = SyntheticROM.sendSerial(0x48) + SyntheticROM.sendSerial(0x69) + SyntheticROM.spin
        let core = try SyntheticROM.core(SyntheticROM.make(program: program))
        core.run(frames: 5)
        #expect(core.serialOutput == [0x48, 0x69])
    }

    @Test func rejectsTinyAndUnsupportedROMs() {
        #expect(throws: GameBoyError.self) { _ = try SyntheticROM.core([UInt8](repeating: 0, count: 100)) }
        let mbc7 = SyntheticROM.make(program: SyntheticROM.spin, cartType: 0x22)
        #expect(throws: GameBoyError.unsupportedMapper(0x22)) { _ = try SyntheticROM.core(mbc7) }
    }

    @Test func mbc1SwitchesRomBanks() throws {
        // Four banks; each bank's first byte at $4000 holds its own number. Read banks 1, 2, 3 and report over serial.
        var extra: [Int: [UInt8]] = [:]
        for bank in 1..<4 { extra[bank * 0x4000] = [UInt8(0xA0 + bank)] }
        var program: [UInt8] = []
        for bank in 1..<4 {
            program += [0x3E, UInt8(bank), 0xEA, 0x00, 0x20]            // LD A,bank ; LD ($2000),A
            program += [0xFA, 0x00, 0x40]                               // LD A,($4000)
            program += [0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02, 0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA]   // send A over serial
        }
        program += SyntheticROM.spin
        let rom = SyntheticROM.make(program: program, cartType: 0x01, banks: 4, at: extra)
        let core = try SyntheticROM.core(rom)
        core.run(frames: 10)
        #expect(core.serialOutput == [0xA1, 0xA2, 0xA3])
    }

    @Test func mbc5BankZeroIsAddressable() throws {
        var extra: [Int: [UInt8]] = [:]
        extra[0x4000 * 3] = [0xC3]
        var program: [UInt8] = [0x3E, 0x03, 0xEA, 0x00, 0x20, 0xFA, 0x00, 0x40]
        program += [0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02, 0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA] + SyntheticROM.spin
        let core = try SyntheticROM.core(SyntheticROM.make(program: program, cartType: 0x19, banks: 4, at: extra))
        core.run(frames: 5)
        #expect(core.serialOutput == [0xC3])
    }

    @Test func batteryRAMRoundTrips() throws {
        // MBC1+RAM+BATTERY: enable RAM, write $5A to $A000.
        var program: [UInt8] = SyntheticROM.store(0x0A, at: 0x0000)
        program += SyntheticROM.store(0x5A, at: 0xA000) + SyntheticROM.spin
        let rom = SyntheticROM.make(program: program, cartType: 0x03, ramCode: 2)
        let core = try SyntheticROM.core(rom)
        core.run(frames: 2)
        let save = try #require(core.batterySave)
        #expect(save.isDirty)
        #expect(save.bytes.count == 8192 && save.bytes[0] == 0x5A)

        let fresh = try SyntheticROM.core(SyntheticROM.make(program: SyntheticROM.spin, cartType: 0x03, ramCode: 2))
        fresh.loadBatterySave(save.bytes)
        #expect(fresh.batterySave?.bytes[0] == 0x5A)
        #expect(fresh.batterySave?.isDirty == false)
    }

    @Test func mbc3RTCFollowsTheInjectedClock() throws {
        final class MutableClock: HostClock, @unchecked Sendable {
            var now: Int64 = 1_000_000
            func unixSeconds() -> Int64 { now }
        }
        let clock = MutableClock()
        // MBC3+TIMER+RAM+BATTERY. Enable RAM/RTC, latch (0 then 1), select the seconds register, read it, report it.
        var program = SyntheticROM.store(0x0A, at: 0x0000)
        program += SyntheticROM.store(0x08, at: 0x4000)                 // select RTC seconds
        program += SyntheticROM.store(0x00, at: 0x6000) + SyntheticROM.store(0x01, at: 0x6000)
        program += [0xFA, 0x00, 0xA0]
        program += [0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02, 0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA] + SyntheticROM.spin
        let core = try SyntheticROM.core(SyntheticROM.make(program: program, cartType: 0x10, ramCode: 2), clock: clock)
        clock.now += 125          // 2 minutes 5 seconds after power-on
        core.run(frames: 5)
        #expect(core.serialOutput == [5])
        let save = try #require(core.batterySave)
        #expect(save.bytes.count == 8192 + 48)
    }

    @Test func rumbleCartridgeReportsDuty() throws {
        // MBC5+RUMBLE: set bit 3 of the RAM-bank register and leave it on.
        let program = SyntheticROM.store(0x08, at: 0x4000) + SyntheticROM.spin
        let core = try SyntheticROM.core(SyntheticROM.make(program: program, cartType: 0x1C))
        let out = TestOutput()
        core.run(frames: 3, output: out)
        #expect(out.rumble.last ?? 0 > 0.9)
    }

    @Test func joypadReadsSelectedButtons() throws {
        // Select the button row (P1 bit 5 low), read P1, report it.
        let program: [UInt8] = [0x3E, 0x10, 0xE0, 0x00, 0xF0, 0x00, 0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02,
                                0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA] + SyntheticROM.spin
        let core = try SyntheticROM.core(SyntheticROM.make(program: program))
        let input = TestInput()
        input.buttons = [.east, .start]                 // A and Start pressed
        core.run(frames: 3, input: input)
        // Buttons are active-low: bits 0 (A) and 3 (Start) read 0 -> low nibble 0b0110.
        #expect(core.serialOutput.first.map { $0 & 0x0F } == 0b0110)
    }

    @Test func timerInterruptFiresAtTheSelectedRate() throws {
        // TAC = enabled, 262144 Hz (TIMA +1 every 16 CPU clocks); count timer interrupts in HRAM.
        let program: [UInt8] = [0x3E, 0x04, 0xE0, 0xFF, 0x3E, 0x05, 0xE0, 0x07, 0xFB, 0x76, 0x18, 0xFD]
        let handler: [UInt8] = [0xF0, 0x80, 0x3C, 0xE0, 0x80, 0xD9]   // LDH A,($80) ; INC A ; LDH ($80),A ; RETI
        let core = try SyntheticROM.core(SyntheticROM.make(program: program, at: [0x50: handler]))
        core.run(frames: 10)
        // 10 frames = 702,240 clocks; one interrupt per 256 TIMA steps of 16 clocks = 4096 clocks.
        let count = Int(core.peek(0xFF80))
        #expect(count >= 168 && count <= 172)
    }
}
