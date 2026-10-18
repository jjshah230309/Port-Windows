// SM83 CPU with M-cycle-accurate memory timing: every bus access advances the rest of the machine by one M-cycle,
// and internal delay cycles do the same through tickM().

private let FZ: UInt8 = 0x80
private let FN: UInt8 = 0x40
private let FH: UInt8 = 0x20
private let FC: UInt8 = 0x10

extension GameBoyCore {
    // MARK: Register pairs

    @inline(__always) var bc: UInt16 {
        get { UInt16(b) << 8 | UInt16(c) }
        set { b = UInt8(newValue >> 8); c = UInt8(truncatingIfNeeded: newValue) }
    }
    @inline(__always) var de: UInt16 {
        get { UInt16(d) << 8 | UInt16(e) }
        set { d = UInt8(newValue >> 8); e = UInt8(truncatingIfNeeded: newValue) }
    }
    @inline(__always) var hl: UInt16 {
        get { UInt16(h) << 8 | UInt16(l) }
        set { h = UInt8(newValue >> 8); l = UInt8(truncatingIfNeeded: newValue) }
    }

    // MARK: Timed bus access

    @inline(__always) func read8(_ addr: UInt16) -> UInt8 {
        tickM()
        return busRead(addr)
    }

    @inline(__always) func write8(_ addr: UInt16, _ value: UInt8) {
        tickM()
        busWrite(addr, value)
    }

    @inline(__always) func fetch8() -> UInt8 {
        let v = read8(pc)
        pc &+= 1
        return v
    }

    @inline(__always) func fetch16() -> UInt16 {
        let lo = UInt16(fetch8())
        let hi = UInt16(fetch8())
        return hi << 8 | lo
    }

    @inline(__always) func push16(_ v: UInt16) {
        sp &-= 1
        write8(sp, UInt8(v >> 8))
        sp &-= 1
        write8(sp, UInt8(truncatingIfNeeded: v))
    }

    @inline(__always) func pop16() -> UInt16 {
        let lo = UInt16(read8(sp))
        sp &+= 1
        let hi = UInt16(read8(sp))
        sp &+= 1
        return hi << 8 | lo
    }

    // MARK: Register-by-index (0=B 1=C 2=D 3=E 4=H 5=L 6=(HL) 7=A)

    @inline(__always) func getR(_ i: UInt8) -> UInt8 {
        switch i {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return h
        case 5: return l
        case 6: return read8(hl)
        default: return a
        }
    }

    @inline(__always) func setR(_ i: UInt8, _ v: UInt8) {
        switch i {
        case 0: b = v
        case 1: c = v
        case 2: d = v
        case 3: e = v
        case 4: h = v
        case 5: l = v
        case 6: write8(hl, v)
        default: a = v
        }
    }

    @inline(__always) func condition(_ cc: UInt8) -> Bool {
        switch cc & 3 {
        case 0: return f & FZ == 0
        case 1: return f & FZ != 0
        case 2: return f & FC == 0
        default: return f & FC != 0
        }
    }

    // MARK: ALU

    @inline(__always) func alu(_ op: UInt8, _ v: UInt8) {
        switch op {
        case 0: addA(v, 0)
        case 1: addA(v, (f & FC) != 0 ? 1 : 0)
        case 2: a = subA(v, 0, store: true)
        case 3: a = subA(v, (f & FC) != 0 ? 1 : 0, store: true)
        case 4: a &= v; f = (a == 0 ? FZ : 0) | FH
        case 5: a ^= v; f = a == 0 ? FZ : 0
        case 6: a |= v; f = a == 0 ? FZ : 0
        default: _ = subA(v, 0, store: false)
        }
    }

    @inline(__always) func addA(_ v: UInt8, _ carry: UInt8) {
        let r = UInt16(a) + UInt16(v) + UInt16(carry)
        var fl: UInt8 = 0
        if (r & 0xFF) == 0 { fl |= FZ }
        if (a & 0xF) + (v & 0xF) + carry > 0xF { fl |= FH }
        if r > 0xFF { fl |= FC }
        a = UInt8(truncatingIfNeeded: r)
        f = fl
    }

    @inline(__always) func subA(_ v: UInt8, _ carry: UInt8, store: Bool) -> UInt8 {
        let r = Int(a) - Int(v) - Int(carry)
        var fl: UInt8 = FN
        if (r & 0xFF) == 0 { fl |= FZ }
        if Int(a & 0xF) - Int(v & 0xF) - Int(carry) < 0 { fl |= FH }
        if r < 0 { fl |= FC }
        f = fl
        return store ? UInt8(truncatingIfNeeded: r) : a
    }

    @inline(__always) func inc8(_ v: UInt8) -> UInt8 {
        let r = v &+ 1
        f = (f & FC) | (r == 0 ? FZ : 0) | ((v & 0xF) == 0xF ? FH : 0)
        return r
    }

    @inline(__always) func dec8(_ v: UInt8) -> UInt8 {
        let r = v &- 1
        f = (f & FC) | FN | (r == 0 ? FZ : 0) | ((v & 0xF) == 0 ? FH : 0)
        return r
    }

    @inline(__always) func addHL(_ v: UInt16) {
        let r = UInt32(hl) + UInt32(v)
        f = (f & FZ) | (((hl & 0x0FFF) + (v & 0x0FFF)) > 0x0FFF ? FH : 0) | (r > 0xFFFF ? FC : 0)
        hl = UInt16(truncatingIfNeeded: r)
        tickM()
    }

    /// SP + signed 8-bit immediate; sets Z=N=0 and H/C from the low byte. Used by ADD SP,e and LD HL,SP+e.
    @inline(__always) func spPlusOffset(_ raw: UInt8) -> UInt16 {
        let off = Int8(bitPattern: raw)
        let r = UInt16(bitPattern: Int16(bitPattern: sp) &+ Int16(off))
        f = (((sp & 0xF) + (UInt16(raw) & 0xF)) > 0xF ? FH : 0) | (((sp & 0xFF) + UInt16(raw)) > 0xFF ? FC : 0)
        return r
    }

    func daa() {
        var adjust: UInt8 = 0
        var carry = f & FC
        if f & FN == 0 {
            if (f & FH) != 0 || (a & 0x0F) > 9 { adjust |= 0x06 }
            if carry != 0 || a > 0x99 { adjust |= 0x60; carry = FC }
            a &+= adjust
        } else {
            if f & FH != 0 { adjust |= 0x06 }
            if carry != 0 { adjust |= 0x60 }
            a &-= adjust
        }
        f = (a == 0 ? FZ : 0) | (f & FN) | carry
    }

    // MARK: Rotates, shifts and CB-prefixed operations

    @inline(__always) func rotateShift(_ y: UInt8, _ v: UInt8) -> UInt8 {
        var r: UInt8
        var carry: UInt8
        switch y {
        case 0: carry = v >> 7; r = (v << 1) | carry                               // RLC
        case 1: carry = v & 1; r = (v >> 1) | (carry << 7)                         // RRC
        case 2: carry = v >> 7; r = (v << 1) | ((f & FC) != 0 ? 1 : 0)             // RL
        case 3: carry = v & 1; r = (v >> 1) | ((f & FC) != 0 ? 0x80 : 0)           // RR
        case 4: carry = v >> 7; r = v << 1                                         // SLA
        case 5: carry = v & 1; r = (v >> 1) | (v & 0x80)                           // SRA
        case 6: carry = 0; r = (v << 4) | (v >> 4)                                 // SWAP
        default: carry = v & 1; r = v >> 1                                         // SRL
        }
        f = (r == 0 ? FZ : 0) | (carry != 0 ? FC : 0)
        return r
    }

    func executeCB() {
        let op = fetch8()
        let z = op & 7
        let y = (op >> 3) & 7
        switch op >> 6 {
        case 0:
            let v = getR(z)
            setR(z, rotateShift(y, v))
        case 1:
            let v = getR(z)
            f = (f & FC) | FH | ((v >> y) & 1 == 0 ? FZ : 0)
        case 2:
            let v = getR(z)
            setR(z, v & ~(1 << y))
        default:
            let v = getR(z)
            setR(z, v | (1 << y))
        }
    }

    // MARK: Interrupts

    func serviceInterrupt() {
        ime = false
        tickM()
        tickM()
        sp &-= 1
        write8(sp, UInt8(pc >> 8))
        // Which interrupt fires is decided after the high byte is pushed; if it was cancelled meanwhile, jump to 0.
        let pending = ie & iflag & 0x1F
        sp &-= 1
        write8(sp, UInt8(truncatingIfNeeded: pc))
        if pending == 0 {
            pc = 0
        } else {
            let bit = pending.trailingZeroBitCount
            iflag &= ~(1 << UInt8(bit))
            pc = 0x40 &+ UInt16(bit) &* 8
        }
        tickM()
    }

    // MARK: Main step

    /// Executes one instruction (or one idle M-cycle while halted) including interrupt dispatch.
    func step() {
        if hdmaPending { runHDMABlock() }

        let applyEI = eiPending
        let pending = ie & iflag & 0x1F

        if halted {
            if pending != 0 {
                halted = false
            } else {
                tickM()
                return
            }
        }
        if stopped {
            latchInput()
            if (joyButtons | joyDpad) != 0 { stopped = false } else { tickM(); return }
        }
        if ime && pending != 0 {
            serviceInterrupt()
            return
        }

        let op = read8(pc)
        if haltBug { haltBug = false } else { pc &+= 1 }
        execute(op)

        if applyEI && eiPending {
            ime = true
            eiPending = false
        }
    }

    @inline(__always) func execute(_ op: UInt8) {
        switch op >> 6 {
        case 1:
            if op == 0x76 {
                if !ime && (ie & iflag & 0x1F) != 0 { haltBug = true } else { halted = true }
            } else {
                setR((op >> 3) & 7, getR(op & 7))
            }
        case 2:
            alu((op >> 3) & 7, getR(op & 7))
        default:
            executeMisc(op)
        }
    }

    func executeMisc(_ op: UInt8) {
        switch op {
        case 0x00: break
        case 0x01: bc = fetch16()
        case 0x11: de = fetch16()
        case 0x21: hl = fetch16()
        case 0x31: sp = fetch16()
        case 0x02: write8(bc, a)
        case 0x12: write8(de, a)
        case 0x22: write8(hl, a); hl &+= 1
        case 0x32: write8(hl, a); hl &-= 1
        case 0x0A: a = read8(bc)
        case 0x1A: a = read8(de)
        case 0x2A: a = read8(hl); hl &+= 1
        case 0x3A: a = read8(hl); hl &-= 1
        case 0x03: bc &+= 1; tickM()
        case 0x13: de &+= 1; tickM()
        case 0x23: hl &+= 1; tickM()
        case 0x33: sp &+= 1; tickM()
        case 0x0B: bc &-= 1; tickM()
        case 0x1B: de &-= 1; tickM()
        case 0x2B: hl &-= 1; tickM()
        case 0x3B: sp &-= 1; tickM()
        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
            let r = (op >> 3) & 7
            setR(r, inc8(getR(r)))
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
            let r = (op >> 3) & 7
            setR(r, dec8(getR(r)))
        case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E:
            setR((op >> 3) & 7, fetch8())
        case 0x07:
            let carry = a >> 7
            a = (a << 1) | carry
            f = carry != 0 ? FC : 0
        case 0x0F:
            let carry = a & 1
            a = (a >> 1) | (carry << 7)
            f = carry != 0 ? FC : 0
        case 0x17:
            let carry = a >> 7
            a = (a << 1) | ((f & FC) != 0 ? 1 : 0)
            f = carry != 0 ? FC : 0
        case 0x1F:
            let carry = a & 1
            a = (a >> 1) | ((f & FC) != 0 ? 0x80 : 0)
            f = carry != 0 ? FC : 0
        case 0x08:
            let addr = fetch16()
            write8(addr, UInt8(truncatingIfNeeded: sp))
            write8(addr &+ 1, UInt8(sp >> 8))
        case 0x09: addHL(bc)
        case 0x19: addHL(de)
        case 0x29: addHL(hl)
        case 0x39: addHL(sp)
        case 0x10:
            _ = fetch8()
            if doubleSpeedSwitchArmed() { performSpeedSwitch() } else { stopped = true }
        case 0x18:
            let off = Int8(bitPattern: fetch8())
            pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(off))
            tickM()
        case 0x20, 0x28, 0x30, 0x38:
            let off = Int8(bitPattern: fetch8())
            if condition((op >> 3) & 3) {
                pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(off))
                tickM()
            }
        case 0x27: daa()
        case 0x2F: a = ~a; f |= FN | FH
        case 0x37: f = (f & FZ) | FC
        case 0x3F: f = (f & FZ) | ((f & FC) != 0 ? 0 : FC)

        case 0xC0, 0xC8, 0xD0, 0xD8:
            tickM()
            if condition((op >> 3) & 3) {
                pc = pop16()
                tickM()
            }
        case 0xC9:
            pc = pop16()
            tickM()
        case 0xD9:
            pc = pop16()
            tickM()
            ime = true
        case 0xC1: bc = pop16()
        case 0xD1: de = pop16()
        case 0xE1: hl = pop16()
        case 0xF1: let v = pop16(); a = UInt8(v >> 8); f = UInt8(truncatingIfNeeded: v) & 0xF0
        case 0xC5: tickM(); push16(bc)
        case 0xD5: tickM(); push16(de)
        case 0xE5: tickM(); push16(hl)
        case 0xF5: tickM(); push16(UInt16(a) << 8 | UInt16(f))
        case 0xC2, 0xCA, 0xD2, 0xDA:
            let target = fetch16()
            if condition((op >> 3) & 3) {
                pc = target
                tickM()
            }
        case 0xC3:
            let target = fetch16()
            pc = target
            tickM()
        case 0xE9: pc = hl
        case 0xC4, 0xCC, 0xD4, 0xDC:
            let target = fetch16()
            if condition((op >> 3) & 3) {
                tickM()
                push16(pc)
                pc = target
            }
        case 0xCD:
            let target = fetch16()
            tickM()
            push16(pc)
            pc = target
        case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF:
            tickM()
            push16(pc)
            pc = UInt16(op & 0x38)
        case 0xC6: alu(0, fetch8())
        case 0xCE: alu(1, fetch8())
        case 0xD6: alu(2, fetch8())
        case 0xDE: alu(3, fetch8())
        case 0xE6: alu(4, fetch8())
        case 0xEE: alu(5, fetch8())
        case 0xF6: alu(6, fetch8())
        case 0xFE: alu(7, fetch8())
        case 0xCB: executeCB()
        case 0xE0: write8(0xFF00 | UInt16(fetch8()), a)
        case 0xF0: a = read8(0xFF00 | UInt16(fetch8()))
        case 0xE2: write8(0xFF00 | UInt16(c), a)
        case 0xF2: a = read8(0xFF00 | UInt16(c))
        case 0xEA: write8(fetch16(), a)
        case 0xFA: a = read8(fetch16())
        case 0xE8:
            let raw = fetch8()
            sp = spPlusOffset(raw)
            tickM()
            tickM()
        case 0xF8:
            let raw = fetch8()
            hl = spPlusOffset(raw)
            tickM()
        case 0xF9: sp = hl; tickM()
        case 0xF3: ime = false; eiPending = false
        case 0xFB: eiPending = true
        default:
            break   // undefined opcodes behave as NOP here
        }
    }
}
