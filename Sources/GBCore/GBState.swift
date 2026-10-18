import EmulatorKit

// Save states: every piece of mutable machine state, in tagged chunks (see StateWriter).

private struct ByteSink {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func int(_ v: Int) {
        var x = UInt64(bitPattern: Int64(v))
        for _ in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: x)); x >>= 8 }
    }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(v >> 8)) }
    mutating func raw(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) { bytes.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
}

private struct ByteSource {
    let bytes: [UInt8]
    var pos = 0
    init(_ b: [UInt8]) { bytes = b }
    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw StateError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func int() throws -> Int {
        var x: UInt64 = 0
        for i in 0..<8 { x |= UInt64(try u8()) << (8 * UInt64(i)) }
        return Int(Int64(bitPattern: x))
    }
    mutating func u16() throws -> UInt16 { UInt16(try u8()) | UInt16(try u8()) << 8 }
    mutating func raw(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) throws {
        guard pos + n <= bytes.count else { throw StateError.truncated }
        for i in 0..<n { p[i] = bytes[pos + i] }
        pos += n
    }
}

extension GameBoyCore {
    private func put(_ s: inout ByteSink, _ ch: SquareChannel) {
        s.bool(ch.enabled); s.bool(ch.dac); s.int(ch.duty); s.int(ch.dutyPos); s.int(ch.freq); s.int(ch.timer)
        s.int(ch.length); s.bool(ch.lengthEnabled); s.int(ch.volume); s.int(ch.envInitial); s.bool(ch.envAdd)
        s.int(ch.envPeriod); s.int(ch.envTimer); s.int(ch.sweepPeriod); s.bool(ch.sweepNegate); s.int(ch.sweepShift)
        s.int(ch.sweepTimer); s.int(ch.sweepShadow); s.bool(ch.sweepEnabled)
    }

    private func get(_ s: inout ByteSource, _ ch: inout SquareChannel) throws {
        ch.enabled = try s.bool(); ch.dac = try s.bool(); ch.duty = try s.int(); ch.dutyPos = try s.int()
        ch.freq = try s.int(); ch.timer = try s.int(); ch.length = try s.int(); ch.lengthEnabled = try s.bool()
        ch.volume = try s.int(); ch.envInitial = try s.int(); ch.envAdd = try s.bool(); ch.envPeriod = try s.int()
        ch.envTimer = try s.int(); ch.sweepPeriod = try s.int(); ch.sweepNegate = try s.bool()
        ch.sweepShift = try s.int(); ch.sweepTimer = try s.int(); ch.sweepShadow = try s.int()
        ch.sweepEnabled = try s.bool()
    }

    public func saveState(into writer: inout StateWriter) {
        var s = ByteSink()
        s.u8(a); s.u8(f); s.u8(b); s.u8(c); s.u8(d); s.u8(e); s.u8(h); s.u8(l)
        s.u16(sp); s.u16(pc)
        s.bool(ime); s.bool(eiPending); s.bool(halted); s.bool(haltBug); s.bool(stopped)
        writer.chunk("CPU ", s.bytes)

        s = ByteSink()
        s.raw(wram, 0x8000); s.raw(vram, 0x4000); s.raw(oam, 0xA0); s.raw(hram, 0x80)
        s.raw(cartRAM, max(cartRAMSize, 1)); s.raw(bgPalRAM, 64); s.raw(objPalRAM, 64)
        writer.chunk("MEM ", s.bytes)

        s = ByteSink()
        s.u8(ie); s.u8(iflag); s.u16(divCounter); s.u8(tima); s.u8(tma); s.u8(tac)
        s.bool(timaReloadPending); s.bool(timaJustReloaded)
        s.u8(sb); s.u8(sc); s.int(serialBits); s.int(serialCounter)
        s.u8(p1Select); s.u8(joyButtons); s.u8(joyDpad)
        s.u8(dmaReg); s.bool(oamDMAActive); s.int(oamDMADelay); s.int(oamDMAIndex); s.int(oamDMASource); s.int(oamDMAPendingSource)
        s.u16(hdmaSource); s.u16(hdmaDest); s.bool(hdmaActive); s.bool(hdmaHBlank); s.int(hdmaBlocks); s.bool(hdmaPending)
        s.bool(doubleSpeed); s.bool(speedArmed); s.int(vramBank); s.int(wramBank)
        s.u8(bcps); s.u8(ocps); s.u8(opri)
        writer.chunk("IO  ", s.bytes)

        s = ByteSink()
        s.u8(lcdc); s.u8(statReg); s.u8(scy); s.u8(scx); s.int(ly); s.u8(lyReg); s.u8(lyc)
        s.u8(bgp); s.u8(obp0); s.u8(obp1); s.u8(wy); s.u8(wx)
        s.bool(lcdOn); s.int(ppuMode); s.int(ppuDot); s.int(ppuEvent); s.int(mode3Length)
        s.bool(statLine); s.bool(lycFlag); s.int(windowLine); s.bool(windowTriggered)
        s.bool(firstLineAfterEnable); s.int(lcdOffDots)
        for i in 0..<(160 * 144) {
            let px = frame[i]
            s.u16(UInt16(truncatingIfNeeded: px)); s.u16(UInt16(truncatingIfNeeded: px >> 16))
        }
        writer.chunk("PPU ", s.bytes)

        s = ByteSink()
        s.bool(apu.power); s.int(apu.frameStep)
        put(&s, apu.ch1); put(&s, apu.ch2)
        s.bool(apu.ch3.enabled); s.bool(apu.ch3.dac); s.int(apu.ch3.freq); s.int(apu.ch3.timer); s.int(apu.ch3.pos)
        s.int(apu.ch3.length); s.bool(apu.ch3.lengthEnabled); s.int(apu.ch3.volumeCode)
        let n = apu.ch4
        s.bool(n.enabled); s.bool(n.dac); s.int(n.lfsr); s.int(n.timer); s.int(n.length); s.bool(n.lengthEnabled)
        s.int(n.volume); s.int(n.envInitial); s.bool(n.envAdd); s.int(n.envPeriod); s.int(n.envTimer)
        s.int(n.clockShift); s.bool(n.widthMode); s.int(n.divisorCode)
        s.u8(apu.nr50); s.u8(apu.nr51)
        s.raw(apuRegs, 0x30)
        s.int(apuSamplePhase); s.int(apuAccumL); s.int(apuAccumR); s.int(apuAccumCount)
        writer.chunk("APU ", s.bytes)

        s = ByteSink()
        s.bool(ramEnabled); s.int(romBank); s.int(ramBank); s.int(mbc1Mode); s.int(mbc1Hi)
        s.bool(rumbleOn); s.int(rtcSelect); s.int(Int(rtcBase)); s.bool(rtcHalted); s.int(Int(rtcFrozen))
        s.bool(rtcCarry); s.u8(rtcLatchPrev)
        for v in rtcLatched { s.u8(v) }
        writer.chunk("CART", s.bytes)
    }

    public func loadState(from reader: inout StateReader) throws {
        while let chunk = try reader.nextChunk() {
            var s = ByteSource(chunk.payload)
            switch chunk.tag {
            case "CPU ":
                a = try s.u8(); f = try s.u8(); b = try s.u8(); c = try s.u8()
                d = try s.u8(); e = try s.u8(); h = try s.u8(); l = try s.u8()
                sp = try s.u16(); pc = try s.u16()
                ime = try s.bool(); eiPending = try s.bool(); halted = try s.bool()
                haltBug = try s.bool(); stopped = try s.bool()
            case "MEM ":
                try s.raw(wram, 0x8000); try s.raw(vram, 0x4000); try s.raw(oam, 0xA0); try s.raw(hram, 0x80)
                try s.raw(cartRAM, max(cartRAMSize, 1)); try s.raw(bgPalRAM, 64); try s.raw(objPalRAM, 64)
                paletteDirty = true
            case "IO  ":
                ie = try s.u8(); iflag = try s.u8(); divCounter = try s.u16()
                tima = try s.u8(); tma = try s.u8(); tac = try s.u8()
                timaReloadPending = try s.bool(); timaJustReloaded = try s.bool()
                sb = try s.u8(); sc = try s.u8(); serialBits = try s.int(); serialCounter = try s.int()
                p1Select = try s.u8(); joyButtons = try s.u8(); joyDpad = try s.u8()
                dmaReg = try s.u8(); oamDMAActive = try s.bool(); oamDMADelay = try s.int()
                oamDMAIndex = try s.int(); oamDMASource = try s.int(); oamDMAPendingSource = try s.int()
                hdmaSource = try s.u16(); hdmaDest = try s.u16(); hdmaActive = try s.bool()
                hdmaHBlank = try s.bool(); hdmaBlocks = try s.int(); hdmaPending = try s.bool()
                doubleSpeed = try s.bool(); speedArmed = try s.bool(); vramBank = try s.int(); wramBank = try s.int()
                bcps = try s.u8(); ocps = try s.u8(); opri = try s.u8()
            case "PPU ":
                lcdc = try s.u8(); statReg = try s.u8(); scy = try s.u8(); scx = try s.u8()
                ly = try s.int(); lyReg = try s.u8(); lyc = try s.u8()
                bgp = try s.u8(); obp0 = try s.u8(); obp1 = try s.u8(); wy = try s.u8(); wx = try s.u8()
                lcdOn = try s.bool(); ppuMode = try s.int(); ppuDot = try s.int()
                ppuEvent = try s.int(); mode3Length = try s.int()
                statLine = try s.bool(); lycFlag = try s.bool(); windowLine = try s.int()
                windowTriggered = try s.bool(); firstLineAfterEnable = try s.bool(); lcdOffDots = try s.int()
                for i in 0..<(160 * 144) {
                    let lo = UInt32(try s.u16()), hi = UInt32(try s.u16())
                    frame[i] = lo | hi << 16
                }
            case "APU ":
                apu.power = try s.bool(); apu.frameStep = try s.int()
                try get(&s, &apu.ch1); try get(&s, &apu.ch2)
                apu.ch3.enabled = try s.bool(); apu.ch3.dac = try s.bool(); apu.ch3.freq = try s.int()
                apu.ch3.timer = try s.int(); apu.ch3.pos = try s.int(); apu.ch3.length = try s.int()
                apu.ch3.lengthEnabled = try s.bool(); apu.ch3.volumeCode = try s.int()
                apu.ch4.enabled = try s.bool(); apu.ch4.dac = try s.bool(); apu.ch4.lfsr = try s.int()
                apu.ch4.timer = try s.int(); apu.ch4.length = try s.int(); apu.ch4.lengthEnabled = try s.bool()
                apu.ch4.volume = try s.int(); apu.ch4.envInitial = try s.int(); apu.ch4.envAdd = try s.bool()
                apu.ch4.envPeriod = try s.int(); apu.ch4.envTimer = try s.int(); apu.ch4.clockShift = try s.int()
                apu.ch4.widthMode = try s.bool(); apu.ch4.divisorCode = try s.int()
                apu.nr50 = try s.u8(); apu.nr51 = try s.u8()
                try s.raw(apuRegs, 0x30)
                apuSamplePhase = try s.int(); apuAccumL = try s.int(); apuAccumR = try s.int()
                apuAccumCount = try s.int()
            case "CART":
                ramEnabled = try s.bool(); romBank = try s.int(); ramBank = try s.int()
                mbc1Mode = try s.int(); mbc1Hi = try s.int(); rumbleOn = try s.bool()
                rtcSelect = try s.int(); rtcBase = Int64(try s.int()); rtcHalted = try s.bool()
                rtcFrozen = Int64(try s.int()); rtcCarry = try s.bool(); rtcLatchPrev = try s.u8()
                for i in 0..<5 { rtcLatched[i] = try s.u8() }
                updateBanks()
            default:
                break
            }
        }
        audioCount = 0
    }
}
