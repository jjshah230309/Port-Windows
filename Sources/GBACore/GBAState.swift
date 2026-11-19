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
    mutating func u64(_ v: UInt64) {
        var x = v
        for _ in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: x)); x >>= 8 }
    }
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
    mutating func u64() throws -> UInt64 {
        var x: UInt64 = 0
        for i in 0..<8 { x |= UInt64(try u8()) << (8 * UInt64(i)) }
        return x
    }
    mutating func raw(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) throws {
        guard pos + n <= bytes.count else { throw StateError.truncated }
        for i in 0..<n { p[i] = bytes[pos + i] }
        pos += n
    }
}

extension GameBoyAdvanceCore {
    public func saveState(into writer: inout StateWriter) {
        var s = ByteSink()
        s.u64(cycleCounter); s.u64(frameCounter)
        s.u16(keyInput)
        writer.chunk("CPU ", s.bytes)

        s = ByteSink()
        s.raw(ewram, Size.ewram); s.raw(iwram, Size.iwram); s.raw(vram, Size.vram)
        s.raw(oam, Size.oam); s.raw(paletteRAM, Size.palette)
        s.raw(ioRegs, Size.ioRegs); s.raw(soundRegs, Size.sound)
        writer.chunk("MEM ", s.bytes)

        s = ByteSink()
        for i in 0..<(240 * 160) {
            let px = frame[i]
            s.u16(UInt16(truncatingIfNeeded: px)); s.u16(UInt16(truncatingIfNeeded: px >> 16))
        }
        writer.chunk("PPU ", s.bytes)
    }

    public func loadState(from reader: inout StateReader) throws {
        while let chunk = try reader.nextChunk() {
            var s = ByteSource(chunk.payload)
            switch chunk.tag {
            case "CPU ":
                cycleCounter = try s.u64(); frameCounter = try s.u64()
                keyInput = try s.u16()
            case "MEM ":
                try s.raw(ewram, Size.ewram); try s.raw(iwram, Size.iwram); try s.raw(vram, Size.vram)
                try s.raw(oam, Size.oam); try s.raw(paletteRAM, Size.palette)
                try s.raw(ioRegs, Size.ioRegs); try s.raw(soundRegs, Size.sound)
            case "PPU ":
                for i in 0..<(240 * 160) {
                    let lo = UInt32(try s.u16()), hi = UInt32(try s.u16())
                    frame[i] = lo | hi << 16
                }
            default:
                break
            }
        }
        audioCount = 0
    }
}
