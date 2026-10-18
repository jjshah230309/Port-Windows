// Memory map, I/O registers, OAM DMA, HDMA, timer, serial and joypad.

extension GameBoyCore {
    // MARK: Machine clock

    /// Advances every subsystem by one CPU M-cycle (4 CPU clocks; in double speed the video and audio see 2 dots).
    @inline(__always) func tickM() {
        timerTickM()
        let dots = doubleSpeed ? 2 : 4
        ppuAdvance(dots)
        apuAdvance(dots)
        if oamDMAActive || oamDMADelay > 0 { oamDMATick() }
        if sc & 0x80 != 0 && serialBits > 0 { serialTick() }
        if rumbleOn { rumbleCycles &+= 1 }
    }

    // MARK: Debug access

    /// Reads a byte without advancing time or tripping PPU/DMA access rules (for tools and tests).
    public func peek(_ addr: UInt16) -> UInt8 {
        let a16 = Int(addr)
        switch addr >> 12 {
        case 0xA, 0xB:
            guard cartRAMSize > 0 else { return 0xFF }
            return mbc == .mbc2 ? cartRAM[a16 & 0x1FF] : cartRAM[(ramBase &+ (a16 & 0x1FFF)) % cartRAMSize]
        case 0x8, 0x9: return vram[vramBank &* 0x2000 &+ (a16 & 0x1FFF)]
        default: return busRead(addr)
        }
    }

    // MARK: Memory map

    @inline(__always) func busRead(_ addr: UInt16) -> UInt8 {
        let a16 = Int(addr)
        switch addr >> 12 {
        case 0x0, 0x1, 0x2, 0x3:
            return rom[bank0Base &+ a16]
        case 0x4, 0x5, 0x6, 0x7:
            return rom[bankXBase &+ (a16 & 0x3FFF)]
        case 0x8, 0x9:
            if lcdOn && ppuMode == 3 { return 0xFF }
            return vram[vramBank &* 0x2000 &+ (a16 & 0x1FFF)]
        case 0xA, 0xB:
            return readCartRAM(addr)
        case 0xC, 0xE:
            return wram[a16 & 0x0FFF]
        case 0xD:
            return wram[wramBank &* 0x1000 &+ (a16 & 0x0FFF)]
        default:
            if addr < 0xFE00 { return wram[wramBank &* 0x1000 &+ (a16 & 0x0FFF)] }
            if addr < 0xFEA0 {
                if oamDMAActive || (lcdOn && ppuMode >= 2) { return 0xFF }
                return oam[a16 - 0xFE00]
            }
            if addr < 0xFF00 { return isCGB ? 0x00 : 0x00 }
            if addr < 0xFF80 { return ioRead(addr) }
            if addr == 0xFFFF { return ie }
            return hram[a16 - 0xFF80]
        }
    }

    @inline(__always) func busWrite(_ addr: UInt16, _ value: UInt8) {
        let a16 = Int(addr)
        switch addr >> 12 {
        case 0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7:
            writeMapper(addr, value)
        case 0x8, 0x9:
            if lcdOn && ppuMode == 3 { return }
            vram[vramBank &* 0x2000 &+ (a16 & 0x1FFF)] = value
        case 0xA, 0xB:
            writeCartRAM(addr, value)
        case 0xC, 0xE:
            wram[a16 & 0x0FFF] = value
        case 0xD:
            wram[wramBank &* 0x1000 &+ (a16 & 0x0FFF)] = value
        default:
            if addr < 0xFE00 { wram[wramBank &* 0x1000 &+ (a16 & 0x0FFF)] = value; return }
            if addr < 0xFEA0 {
                if oamDMAActive || (lcdOn && ppuMode >= 2) { return }
                oam[a16 - 0xFE00] = value
                return
            }
            if addr < 0xFF00 { return }
            if addr < 0xFF80 { ioWrite(addr, value); return }
            if addr == 0xFFFF { ie = value; return }
            hram[a16 - 0xFF80] = value
        }
    }

    /// Bus read used by DMA engines: no PPU access blocking, echo RAM mapped.
    func dmaRead(_ addr: Int) -> UInt8 {
        let a = UInt16(truncatingIfNeeded: addr)
        switch a >> 12 {
        case 0x8, 0x9: return vram[vramBank &* 0x2000 &+ (addr & 0x1FFF)]
        case 0xE, 0xF: return wram[(addr & 0x0FFF) &+ (a >= 0xF000 ? wramBank &* 0x1000 : 0)]
        default: return busRead(a)
        }
    }

    // MARK: I/O registers

    func ioRead(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0xFF00: return joypadRead()
        case 0xFF01: return sb
        case 0xFF02: return sc | (isCGB ? 0x7C : 0x7E)
        case 0xFF04: return UInt8(truncatingIfNeeded: divCounter >> 8)
        case 0xFF05: return tima
        case 0xFF06: return tma
        case 0xFF07: return tac | 0xF8
        case 0xFF0F: return iflag | 0xE0
        case 0xFF10...0xFF3F: return apuRead(addr)
        case 0xFF40: return lcdc
        case 0xFF41: return statRead()
        case 0xFF42: return scy
        case 0xFF43: return scx
        case 0xFF44: return lcdOn ? lyReg : 0
        case 0xFF45: return lyc
        case 0xFF46: return dmaReg
        case 0xFF47: return bgp
        case 0xFF48: return obp0
        case 0xFF49: return obp1
        case 0xFF4A: return wy
        case 0xFF4B: return wx
        default: break
        }
        guard isCGB else { return 0xFF }
        switch addr {
        case 0xFF4D: return (doubleSpeed ? 0x80 : 0) | (speedArmed ? 1 : 0) | 0x7E
        case 0xFF4F: return UInt8(vramBank) | 0xFE
        case 0xFF51: return UInt8(hdmaSource >> 8)
        case 0xFF52: return UInt8(truncatingIfNeeded: hdmaSource)
        case 0xFF53: return UInt8(hdmaDest >> 8)
        case 0xFF54: return UInt8(truncatingIfNeeded: hdmaDest)
        case 0xFF55: return hdmaActive ? UInt8((hdmaBlocks - 1) & 0x7F) : 0xFF
        case 0xFF56: return 0x3E
        case 0xFF68: return bcps | 0x40
        case 0xFF69: return bgPalRAM[Int(bcps & 0x3F)]
        case 0xFF6A: return ocps | 0x40
        case 0xFF6B: return objPalRAM[Int(ocps & 0x3F)]
        case 0xFF6C: return opri | 0xFE
        case 0xFF70: return UInt8(wramBank) | 0xF8
        default: return 0xFF
        }
    }

    func ioWrite(_ addr: UInt16, _ v: UInt8) {
        switch addr {
        case 0xFF00: p1Select = v & 0x30
        case 0xFF01: sb = v
        case 0xFF02:
            sc = v & (isCGB ? 0x83 : 0x81)
            if sc & 0x81 == 0x81 {
                serialBits = 8
                serialCounter = 0
                serialOutput.append(sb)
            } else {
                serialBits = 0
            }
        case 0xFF04: divWrite()
        case 0xFF05:
            // A write in the cycle of the overflow cancels the reload; in the reload cycle itself it is ignored.
            if !timaJustReloaded {
                tima = v
                timaReloadPending = false
            }
        case 0xFF06:
            tma = v
            if timaJustReloaded { tima = v }
        case 0xFF07: timerControlWrite(v & 7)
        case 0xFF0F: iflag = v & 0x1F
        case 0xFF10...0xFF3F: apuWrite(addr, v)
        case 0xFF40: lcdcWrite(v)
        case 0xFF41:
            statReg = v & 0x78
            updateStatLine()
        case 0xFF42: scy = v
        case 0xFF43: scx = v
        case 0xFF44: break
        case 0xFF45:
            lyc = v
            updateLYCFlag()
        case 0xFF46: startOAMDMA(v)
        case 0xFF47: bgp = v
        case 0xFF48: obp0 = v
        case 0xFF49: obp1 = v
        case 0xFF4A: wy = v
        case 0xFF4B: wx = v
        default: break
        }
        guard isCGB else { return }
        switch addr {
        case 0xFF4D: speedArmed = v & 1 != 0
        case 0xFF4F: vramBank = Int(v & 1)
        case 0xFF51: hdmaSource = (UInt16(v) << 8) | (hdmaSource & 0x00FF)
        case 0xFF52: hdmaSource = (hdmaSource & 0xFF00) | UInt16(v & 0xF0)
        case 0xFF53: hdmaDest = (UInt16(v & 0x1F) << 8) | (hdmaDest & 0x00FF)
        case 0xFF54: hdmaDest = (hdmaDest & 0xFF00) | UInt16(v & 0xF0)
        case 0xFF55: hdmaWrite(v)
        case 0xFF68: bcps = v & 0xBF
        case 0xFF69:
            bgPalRAM[Int(bcps & 0x3F)] = v
            paletteDirty = true
            if bcps & 0x80 != 0 { bcps = 0x80 | ((bcps &+ 1) & 0x3F) }
        case 0xFF6A: ocps = v & 0xBF
        case 0xFF6B:
            objPalRAM[Int(ocps & 0x3F)] = v
            paletteDirty = true
            if ocps & 0x80 != 0 { ocps = 0x80 | ((ocps &+ 1) & 0x3F) }
        case 0xFF6C: opri = v & 1
        case 0xFF70:
            let n = Int(v & 7)
            wramBank = n == 0 ? 1 : n
        default: break
        }
    }

    // MARK: Timer

    /// Selected DIV bit for TIMA: 9, 3, 5, 7 for TAC & 3 = 0...3.
    @inline(__always) var timerBitMask: UInt16 {
        switch tac & 3 {
        case 0: return 1 << 9
        case 1: return 1 << 3
        case 2: return 1 << 5
        default: return 1 << 7
        }
    }

    @inline(__always) func timerTickM() {
        timaJustReloaded = false
        if timaReloadPending {
            timaReloadPending = false
            tima = tma
            iflag |= 0x04
            timaJustReloaded = true
        }
        let old = divCounter
        divCounter &+= 4
        if tac & 4 != 0 && (old & timerBitMask) != 0 && (divCounter & timerBitMask) == 0 { incrementTIMA() }
        let apuBit: UInt16 = doubleSpeed ? 1 << 13 : 1 << 12
        if (old & apuBit) != 0 && (divCounter & apuBit) == 0 { apuFrameSequencerStep() }
    }

    @inline(__always) func incrementTIMA() {
        if tima == 0xFF {
            tima = 0
            timaReloadPending = true
        } else {
            tima &+= 1
        }
    }

    func divWrite() {
        let old = divCounter
        divCounter = 0
        if tac & 4 != 0 && (old & timerBitMask) != 0 { incrementTIMA() }
        let apuBit: UInt16 = doubleSpeed ? 1 << 13 : 1 << 12
        if (old & apuBit) != 0 { apuFrameSequencerStep() }
    }

    func timerControlWrite(_ v: UInt8) {
        let wasHigh = tac & 4 != 0 && (divCounter & timerBitMask) != 0
        tac = v
        let nowHigh = tac & 4 != 0 && (divCounter & timerBitMask) != 0
        if wasHigh && !nowHigh { incrementTIMA() }
    }

    // MARK: Serial (no link partner: transfers complete with 0xFF received)

    func serialTick() {
        serialCounter += 4
        let period = (isCGB && sc & 2 != 0) ? 16 : 512
        if serialCounter >= period {
            serialCounter -= period
            sb = (sb << 1) | 1
            serialBits -= 1
            if serialBits == 0 {
                sc &= ~0x80
                iflag |= 0x08
            }
        }
    }

    // MARK: Joypad

    func latchInput() {
        guard !inputLatched, let source = inputSource else { return }
        inputLatched = true
        let s = source.snapshot(port: 0)
        var buttons: UInt8 = 0
        if s.buttons.contains(.east) { buttons |= 0x01 }      // A
        if s.buttons.contains(.south) { buttons |= 0x02 }     // B
        if s.buttons.contains(.select) { buttons |= 0x04 }
        if s.buttons.contains(.start) { buttons |= 0x08 }
        var dpad: UInt8 = 0
        if s.buttons.contains(.right) { dpad |= 0x01 }
        if s.buttons.contains(.left) { dpad |= 0x02 }
        if s.buttons.contains(.up) { dpad |= 0x04 }
        if s.buttons.contains(.down) { dpad |= 0x08 }
        let before = joypadLines()
        joyButtons = buttons
        joyDpad = dpad
        let after = joypadLines()
        if before & ~after & 0x0F != 0 { iflag |= 0x10 }   // a selected line went high -> low
    }

    @inline(__always) func joypadLines() -> UInt8 {
        var low: UInt8 = 0x0F
        if p1Select & 0x10 == 0 { low &= ~joyDpad }
        if p1Select & 0x20 == 0 { low &= ~joyButtons }
        return low
    }

    func joypadRead() -> UInt8 {
        latchInput()
        return 0xC0 | p1Select | joypadLines()
    }

    // MARK: OAM DMA

    func startOAMDMA(_ v: UInt8) {
        dmaReg = v
        oamDMAPendingSource = Int(v) << 8
        oamDMADelay = oamDMAStartDelay    // a running transfer keeps going until the new one takes over
    }

    func oamDMATick() {
        if oamDMADelay > 0 {
            oamDMADelay -= 1
            if oamDMADelay == 0 {
                oamDMAActive = true
                oamDMAIndex = 0
                oamDMASource = oamDMAPendingSource
                return
            }
        }
        if oamDMAActive {
            oam[oamDMAIndex] = dmaRead(oamDMASource &+ oamDMAIndex)
            oamDMAIndex += 1
            if oamDMAIndex >= 160 { oamDMAActive = false }
        }
    }

    // MARK: CGB VRAM DMA

    func hdmaWrite(_ v: UInt8) {
        if hdmaActive && hdmaHBlank && v & 0x80 == 0 {
            hdmaActive = false          // cancel an HBlank transfer in progress
            return
        }
        hdmaBlocks = Int(v & 0x7F) + 1
        if v & 0x80 != 0 {
            hdmaActive = true
            hdmaHBlank = true
            if lcdOn && ppuMode == 0 { hdmaPending = true }
        } else {
            hdmaHBlank = false
            hdmaActive = false
            while hdmaBlocks > 0 { copyHDMABlock() }
        }
    }

    func runHDMABlock() {
        hdmaPending = false
        if hdmaActive && hdmaHBlank { copyHDMABlock() }
    }

    func copyHDMABlock() {
        for _ in 0..<16 {
            let byte = dmaRead(Int(hdmaSource))
            vram[vramBank &* 0x2000 &+ (Int(hdmaDest) & 0x1FFF)] = byte
            hdmaSource &+= 1
            hdmaDest = (hdmaDest &+ 1) & 0x1FFF
        }
        hdmaBlocks -= 1
        if hdmaBlocks <= 0 { hdmaActive = false; hdmaBlocks = 0 }
        for _ in 0..<(doubleSpeed ? 16 : 8) { tickM() }
    }

    // MARK: CGB speed switch

    func doubleSpeedSwitchArmed() -> Bool { isCGB && speedArmed }

    func performSpeedSwitch() {
        speedArmed = false
        doubleSpeed.toggle()
        divCounter = 0
        for _ in 0..<2050 { tickM() }
    }
}
