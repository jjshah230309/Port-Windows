// Memory map: BIOS, cartridge ROM, EWRAM, IWRAM, I/O + palette RAM, VRAM, OAM, the sound
// registers and the Game Boy compatibility window.
//
// The regions follow GBATEK's map for the GBA:
//
//   00000000-00003FFFh  BIOS
//   00004000-01FFFFFFh  cartridge ROM, mirrored from 08000000h
//   02000000-02FFFFFFh  EWRAM (256 KiB, mirrored)
//   03000000-03FFFFFFh  IWRAM (32 KiB, mirrored)
//   04000000-040003FFh  I/O registers
//   04000400-04000FFFh  palette RAM (1 KiB, mirrored every 400h)
//   05000000-05001FFFh  OAM (1 KiB, mirrored every 400h)
//   06000000-06017FFFh  VRAM (96 KiB)
//   07000000-070003FFh  sound registers
//   08000000-09FFFFFFh  cartridge ROM (32 MiB)
//   0E000000-0E00FFFFh  the Game Boy compatibility window
//
// Two of the brief's regions are not where the hardware puts them, so they are aliased rather than
// moved: the cartridge ROM is also visible in the low window above the BIOS, and VRAM is also
// visible at 04001000h-04017FFFh. The brief also puts palette RAM at 04000000h, where the hardware
// has the I/O registers; the registers keep their place and palette RAM starts at 04000400h,
// inside the window the brief describes.
//
// The cartridge's own window (save media, GPIO) belongs to the cartridge layer and is not wired
// up yet.

extension GameBoyAdvanceCore {
    // MARK: Region bounds

    /// The BIOS region at the bottom of the address space. The GBA's boot BIOS is 16 KiB.
    static let biosSize = 0x4000
    /// The cartridge ROM window, 32 MiB at 0x08000000.
    static let cartRomBase: UInt32 = 0x0800_0000
    /// The low mirror of the cartridge ROM starts just above the BIOS.
    static let romMirrorBase: UInt32 = 0x0000_4000
    /// KEYINPUT, the read-only pad register inside the I/O window.
    static let keyInputOffset = 0x130
    /// The first 0xC0 bytes of IWRAM belong to the BIOS and the interrupt vectors: writing them
    /// has no effect.
    static let iwramProtected = 0xC0
    /// VRAM is 96 KiB at 0x06000000.
    static let vramBase: UInt32 = 0x0600_0000
    /// OAM sits at 0x05000000; the window above the first KiB mirrors it.
    static let oamBase: UInt32 = 0x0500_0000
    /// The sound registers sit at 0x07000000.
    static let soundBase: UInt32 = 0x0700_0000
    /// The Game Boy compatibility window, 16 KiB at 0x0E000000.
    static let gbWindowBase: UInt32 = 0x0E00_0000
    static let gbWindowSize = 0x4000

    // MARK: Memory map

    /// Reads a byte from the machine's address space.
    @inline(__always) func read8(_ addr: UInt32) -> UInt8 {
        switch addr >> 24 {
        case 0x00, 0x01:
            // The boot BIOS owns the low 16 KiB; the cartridge ROM is mirrored above it.
            if addr < Self.biosSize { return bios[Int(addr)] }
            return readROM(addr &- Self.romMirrorBase)
        case 0x02:
            return ewram[Int(addr & 0x3_FFFF)]        // 256 KiB, mirrored
        case 0x03:
            return iwram[Int(addr & 0x7_FFF)]          // 32 KiB, mirrored
        case 0x04:
            return readIO(addr)
        case 0x05:
            return readOAM(addr)
        case 0x06:
            return addr < Self.vramBase &+ UInt32(Size.vram) ? vram[Int(addr &- Self.vramBase)] : 0
        case 0x07:
            return addr < Self.soundBase &+ UInt32(Size.sound) ? soundRegs[Int(addr &- Self.soundBase)] : 0
        case 0x08, 0x09:
            return readROM(addr &- Self.cartRomBase)
        case 0x0E:
            return addr < Self.gbWindowBase &+ UInt32(Self.gbWindowSize) ? gbWindow[Int(addr &- Self.gbWindowBase)] : 0
        default:
            return 0                                    // undriven bus reads back as zero
        }
    }

    /// Writes a byte into the machine's address space.
    @inline(__always) func write8(_ addr: UInt32, _ v: UInt8) {
        switch addr >> 24 {
        case 0x00, 0x01, 0x08, 0x09:
            break                                         // ROM and BIOS are read-only
        case 0x02:
            ewram[Int(addr & 0x3_FFFF)] = v
        case 0x03:
            if Int(addr & 0x7_FFF) >= Self.iwramProtected { iwram[Int(addr & 0x7_FFF)] = v }
        case 0x04:
            writeIO(addr, v)
        case 0x05:
            writeOAM(addr, v)
        case 0x06:
            if addr < Self.vramBase &+ UInt32(Size.vram) { vram[Int(addr &- Self.vramBase)] = v }
        case 0x07:
            if addr < Self.soundBase &+ UInt32(Size.sound) { soundRegs[Int(addr &- Self.soundBase)] = v }
        case 0x0E:
            if addr < Self.gbWindowBase &+ UInt32(Self.gbWindowSize) { gbWindow[Int(addr &- Self.gbWindowBase)] = v }
        default:
            break                                         // writes to unmapped space are dropped
        }
    }

    // MARK: Region helpers

    /// Cartridge ROM, seen at 0x08000000 and mirrored through the low window.
    ///
    /// The offset is taken inside the 32 MiB cartridge window and then wrapped to the size the
    /// cartridge actually has, so a 32 KiB cartridge repeats all the way up the window.
    @inline(__always) func readROM(_ offset: UInt32) -> UInt8 {
        return rom[Int(offset) % romSize]
    }

    /// The I/O window at 0x04000000: the registers, then palette RAM, then the VRAM alias.
    ///
    /// The hardware puts the I/O register mirror at 04010000h, but the brief wants VRAM there, so
    /// the alias wins: 04001000h-04018FFFh is the 96 KiB of VRAM.
    @inline(__always) func readIO(_ addr: UInt32) -> UInt8 {
        let off = Int(addr & 0x1_FFFF)
        if off < Size.ioRegs {
            if off == Self.keyInputOffset {
                latchInput()                            // the pad is latched on the guest's first read
                return UInt8(truncatingIfNeeded: keyInput)
            }
            return ioRegs[off]
        }
        if off < 0x1000 { return paletteRAM[off & 0x3FF] }        // palette RAM, mirrored every 400h
        if off - 0x1000 < Size.vram { return vram[off - 0x1000] } // the VRAM alias
        return 0
    }

    @inline(__always) func writeIO(_ addr: UInt32, _ v: UInt8) {
        let off = Int(addr & 0x1_FFFF)
        if off < Size.ioRegs {
            if off == Self.keyInputOffset { return }               // KEYINPUT is read-only
            ioRegs[off] = v
        } else if off < 0x1000 {
            paletteRAM[off & 0x3FF] = v
        } else if off - 0x1000 < Size.vram {
            vram[off - 0x1000] = v
        }
    }

    /// OAM at 0x05000000; the window above the first KiB mirrors it.
    @inline(__always) func readOAM(_ addr: UInt32) -> UInt8 {
        guard addr < Self.oamBase &+ 0x2000 else { return 0 }
        return oam[Int(addr &- Self.oamBase) & 0x3FF]
    }

    @inline(__always) func writeOAM(_ addr: UInt32, _ v: UInt8) {
        guard addr < Self.oamBase &+ 0x2000 else { return }
        oam[Int(addr &- Self.oamBase) & 0x3FF] = v
    }

    // MARK: Debug access

    /// Reads a byte without side effects (for tools and tests): the pad is not latched here.
    public func peek(_ addr: UInt32) -> UInt8 {
        if addr == 0x0400_0130 { return UInt8(truncatingIfNeeded: keyInput) }
        return read8(addr)
    }

    // MARK: Input

    /// Latches the pad on the first guest read of the frame. KEYINPUT is active low, so a pressed
    /// button reads 0.
    func latchInput() {
        guard !inputLatched, let source = inputSource else { return }
        inputLatched = true
        let s = source.snapshot(port: 0)
        var bits: UInt16 = 0
        if s.buttons.contains(.east) { bits |= 0x0001 }      // A
        if s.buttons.contains(.south) { bits |= 0x0002 }     // B
        if s.buttons.contains(.select) { bits |= 0x0004 }
        if s.buttons.contains(.start) { bits |= 0x0008 }
        if s.buttons.contains(.right) { bits |= 0x0010 }
        if s.buttons.contains(.left) { bits |= 0x0020 }
        if s.buttons.contains(.up) { bits |= 0x0040 }
        if s.buttons.contains(.down) { bits |= 0x0080 }
        if s.buttons.contains(.r1) { bits |= 0x0100 }        // R
        if s.buttons.contains(.l1) { bits |= 0x0200 }        // L
        keyInput = ~bits
    }
}
