import EmulatorKit

// Cartridge mappers (none, MBC1, MBC2, MBC3 + RTC, MBC5 + rumble) and battery-backed RAM.

extension GameBoyCore {
    // MARK: Bank offsets

    /// Recomputes the cached byte offsets of the switchable ROM windows and the RAM window.
    func updateBanks() {
        let mask = romBankCount - 1
        switch mbc {
        case .none:
            bank0Base = 0
            bankXBase = 0x4000
            ramBase = 0
        case .mbc1:
            var lo = romBank & 0x1F
            if lo == 0 { lo = 1 }
            let hi = mbc1Hi & 3
            bankXBase = (((hi << 5) | lo) & mask) * 0x4000
            bank0Base = mbc1Mode == 1 ? ((hi << 5) & mask) * 0x4000 : 0
            ramBase = mbc1Mode == 1 ? hi * 0x2000 : 0
        case .mbc2:
            var bank = romBank & 0x0F
            if bank == 0 { bank = 1 }
            bank0Base = 0
            bankXBase = (bank & mask) * 0x4000
            ramBase = 0
        case .mbc3:
            var bank = romBank & 0x7F
            if bank == 0 { bank = 1 }
            bank0Base = 0
            bankXBase = (bank & mask) * 0x4000
            ramBase = (ramBank & 3) * 0x2000
        case .mbc5:
            bank0Base = 0
            bankXBase = (romBank & 0x1FF & mask) * 0x4000
            ramBase = (ramBank & 0x0F) * 0x2000
        }
    }

    // MARK: Mapper register writes (0000-7FFF)

    func writeMapper(_ addr: UInt16, _ v: UInt8) {
        switch mbc {
        case .none:
            break
        case .mbc1:
            switch addr >> 13 {
            case 0: ramEnabled = v & 0x0F == 0x0A
            case 1: romBank = Int(v & 0x1F)
            case 2: mbc1Hi = Int(v & 3)
            default: mbc1Mode = Int(v & 1)
            }
            updateBanks()
        case .mbc2:
            if addr < 0x4000 {
                if addr & 0x0100 == 0 { ramEnabled = v & 0x0F == 0x0A } else { romBank = Int(v & 0x0F); updateBanks() }
            }
        case .mbc3:
            switch addr >> 13 {
            case 0: ramEnabled = v & 0x0F == 0x0A
            case 1: romBank = Int(v & 0x7F); updateBanks()
            case 2:
                if v <= 3 { ramBank = Int(v); rtcSelect = 0 } else if v >= 8 && v <= 0x0C { rtcSelect = Int(v) }
                updateBanks()
            default:
                if rtcLatchPrev == 0 && v == 1 && hasRTC { latchRTC() }
                rtcLatchPrev = v
            }
        case .mbc5:
            switch addr >> 12 {
            case 0, 1: ramEnabled = v & 0x0F == 0x0A
            case 2: romBank = (romBank & 0x100) | Int(v)
            case 3: romBank = (romBank & 0x0FF) | (Int(v & 1) << 8)
            case 4, 5:
                if hasRumble {
                    ramBank = Int(v & 0x07)
                    rumbleOn = v & 0x08 != 0
                } else {
                    ramBank = Int(v & 0x0F)
                }
            default: break
            }
            updateBanks()
        }
    }

    // MARK: Cartridge RAM (A000-BFFF)

    func readCartRAM(_ addr: UInt16) -> UInt8 {
        guard ramEnabled else { return 0xFF }
        switch mbc {
        case .mbc2:
            return (cartRAM[Int(addr) & 0x1FF] & 0x0F) | 0xF0
        case .mbc3 where rtcSelect >= 8:
            return hasRTC ? rtcLatched[rtcSelect - 8] : 0xFF
        default:
            guard cartRAMSize > 0 else { return 0xFF }
            return cartRAM[(ramBase &+ (Int(addr) & 0x1FFF)) % cartRAMSize]
        }
    }

    func writeCartRAM(_ addr: UInt16, _ v: UInt8) {
        guard ramEnabled else { return }
        switch mbc {
        case .mbc2:
            cartRAM[Int(addr) & 0x1FF] = v & 0x0F
            ramDirty = true
        case .mbc3 where rtcSelect >= 8:
            if hasRTC { writeRTCRegister(rtcSelect - 8, v) }
        default:
            guard cartRAMSize > 0 else { return }
            cartRAM[(ramBase &+ (Int(addr) & 0x1FFF)) % cartRAMSize] = v
            ramDirty = true
        }
    }

    // MARK: MBC3 real-time clock

    /// Seconds elapsed on the cartridge clock.
    func rtcTotalSeconds() -> Int64 {
        if rtcHalted { return rtcFrozen }
        return max(0, clock.unixSeconds() - rtcBase)
    }

    /// Current clock as [seconds, minutes, hours, day-low, day-high/flags].
    func rtcRegisters() -> [UInt8] {
        let total = rtcTotalSeconds()
        let days = total / 86_400
        if days > 511 { rtcCarry = true }
        let day = Int(days & 0x1FF)
        let high: UInt8 = UInt8(day >> 8) | (rtcHalted ? 0x40 : 0) | (rtcCarry ? 0x80 : 0)
        return [UInt8(total % 60), UInt8((total / 60) % 60), UInt8((total / 3600) % 24), UInt8(day & 0xFF), high]
    }

    func latchRTC() { rtcLatched = rtcRegisters() }

    func writeRTCRegister(_ index: Int, _ v: UInt8) {
        var regs = rtcRegisters()
        regs[index] = v
        let day = Int64(regs[3]) | (Int64(regs[4] & 1) << 8)
        let total = Int64(regs[0] % 60) + Int64(regs[1] % 60) * 60 + Int64(regs[2] % 24) * 3600 + day * 86_400
        rtcCarry = regs[4] & 0x80 != 0
        let halt = regs[4] & 0x40 != 0
        if halt {
            rtcFrozen = total
        } else {
            rtcBase = clock.unixSeconds() - total
        }
        rtcHalted = halt
    }

    // MARK: Battery save

    public var batterySave: BatterySave? {
        guard hasBattery else { return nil }
        var bytes = [UInt8](UnsafeBufferPointer(start: cartRAM, count: cartRAMSize))
        if hasRTC {
            let live = rtcRegisters()
            for r in live + rtcLatched { bytes += [r, 0, 0, 0] }
            let now = UInt64(bitPattern: clock.unixSeconds())
            for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: now >> (8 * UInt64(i)))) }
        }
        return BatterySave(bytes: bytes, isDirty: ramDirty)
    }

    public func markBatterySaved() { ramDirty = false }

    /// Restores battery RAM (and the RTC trailer, 48 bytes, when present).
    public func loadBatterySave(_ bytes: [UInt8]) {
        let n = min(cartRAMSize, bytes.count)
        for i in 0..<n { cartRAM[i] = bytes[i] }
        if hasRTC && bytes.count >= cartRAMSize + 48 {
            let t = Array(bytes[cartRAMSize...])
            let live = (0..<5).map { t[$0 * 4] }
            rtcLatched = (0..<5).map { t[20 + $0 * 4] }
            var stamp: UInt64 = 0
            for i in 0..<8 { stamp |= UInt64(t[40 + i]) << (8 * UInt64(i)) }
            let day = Int64(live[3]) | (Int64(live[4] & 1) << 8)
            let total = Int64(live[0] % 60) + Int64(live[1] % 60) * 60 + Int64(live[2] % 24) * 3600 + day * 86_400
            rtcCarry = live[4] & 0x80 != 0
            rtcHalted = live[4] & 0x40 != 0
            if rtcHalted {
                rtcFrozen = total
            } else {
                let elapsed = max(0, clock.unixSeconds() - Int64(bitPattern: stamp))
                rtcBase = clock.unixSeconds() - (total + elapsed)
            }
        }
        ramDirty = false
    }
}
