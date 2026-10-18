// PPU: dot-accurate mode timing with a scanline renderer. A line is drawn when mode 3 ends, from the register
// state at that moment, which is what test ROMs such as dmg-acid2 rely on.

private let lineDots = 456

extension GameBoyCore {
    // MARK: Timing

    @inline(__always) func ppuAdvance(_ dots: Int) {
        if !lcdOn {
            lcdOffDots &+= dots
            if lcdOffDots >= 70_224 {
                lcdOffDots -= 70_224
                blankFrame()
                frameDone = true
            }
            return
        }
        ppuDot &+= dots
        while ppuDot >= nextPPUEventDot() { ppuHandleEvent() }
    }

    /// Dot (within the current line) of the next state change.
    @inline(__always) func nextPPUEventDot() -> Int {
        if ly < 144 {
            switch ppuEvent {
            case 0: return 80
            case 1: return 80 + mode3Length
            default: return lineDots
            }
        }
        if ly == 153 && ppuEvent == 0 { return 4 }
        return lineDots
    }

    func ppuHandleEvent() {
        if ly < 144 {
            switch ppuEvent {
            case 0:     // OAM scan -> drawing
                ppuMode = 3
                ppuEvent = 1
                mode3Length = computeMode3Length()
            case 1:     // drawing -> HBlank
                renderScanline()
                ppuMode = 0
                ppuEvent = 2
                if hdmaActive && hdmaHBlank { hdmaPending = true }
                updateStatLine()
            default:
                endOfLine()
            }
            return
        }
        if ly == 153 && ppuEvent == 0 {
            lyReg = 0               // LY reads 0 for most of the last line
            ppuEvent = 1
            updateLYCFlag()
            return
        }
        endOfLine()
    }

    func endOfLine() {
        ppuDot -= lineDots
        ly += 1
        if ly == 154 {
            ly = 0
            windowLine = 0
            windowTriggered = false
        }
        lyReg = UInt8(ly)
        ppuEvent = 0
        if ly < 144 {
            if firstLineAfterEnable {
                firstLineAfterEnable = false
                ppuMode = 0
            } else {
                ppuMode = 2
            }
            if lcdc & 0x20 != 0 && ly == Int(wy) { windowTriggered = true }
        } else {
            ppuMode = 1
            if ly == 144 {
                iflag |= 0x01
                frameDone = true
            }
        }
        updateLYCFlag()
    }

    func computeMode3Length() -> Int {
        var length = 172 + Int(scx & 7)
        if lcdc & 0x20 != 0 && windowTriggered && Int(wx) < 167 { length += 6 }
        if lcdc & 0x02 != 0 {
            let height = lcdc & 0x04 != 0 ? 16 : 8
            var count = 0
            for i in 0..<40 {
                let y = Int(oam[i * 4]) - 16
                if ly >= y && ly < y + height {
                    count += 1
                    if count == 10 { break }
                }
            }
            length += count * 6
        }
        return length
    }

    // MARK: STAT / LYC

    func updateLYCFlag() {
        lycFlag = lyReg == lyc
        updateStatLine()
    }

    func updateStatLine() {
        let mode = lcdOn ? ppuMode : 0
        let line = lcdOn && (
            (lycFlag && statReg & 0x40 != 0)
            || (mode == 0 && statReg & 0x08 != 0)
            || (mode == 1 && statReg & 0x10 != 0)
            || (mode == 2 && statReg & 0x20 != 0))
        if line && !statLine { iflag |= 0x02 }
        statLine = line
    }

    func statRead() -> UInt8 {
        guard lcdOn else { return 0x80 | (statReg & 0x78) }
        return 0x80 | (statReg & 0x78) | (lycFlag ? 0x04 : 0) | UInt8(ppuMode)
    }

    func lcdcWrite(_ v: UInt8) {
        let wasOn = lcdc & 0x80 != 0
        lcdc = v
        let nowOn = v & 0x80 != 0
        if wasOn && !nowOn {
            lcdOn = false
            ly = 0; lyReg = 0; ppuDot = 0; ppuMode = 0; ppuEvent = 0
            windowLine = 0; windowTriggered = false
            lcdOffDots = 0
            statLine = false
            blankFrame()
        } else if !wasOn && nowOn {
            lcdOn = true
            ly = 0; lyReg = 0; ppuDot = 0; ppuEvent = 0
            ppuMode = 0
            firstLineAfterEnable = true
            if v & 0x20 != 0 && wy == 0 { windowTriggered = true }
            // The first line after enabling skips OAM scan: drawing starts at dot 80 as usual.
            lycFlag = lyc == 0
            updateStatLine()
        }
    }

    func blankFrame() {
        let white: UInt32 = dmgColors[0]
        for i in 0..<(160 * 144) { frame[i] = white }
    }

    // MARK: Rendering

    @inline(__always) func cgbColor(_ ram: UnsafeMutablePointer<UInt8>, _ index: Int) -> UInt32 {
        let v = UInt32(ram[index * 2]) | (UInt32(ram[index * 2 + 1]) << 8)
        let r = v & 0x1F, g = (v >> 5) & 0x1F, bl = (v >> 10) & 0x1F
        let r8 = (r << 3) | (r >> 2), g8 = (g << 3) | (g >> 2), b8 = (bl << 3) | (bl >> 2)
        return 0xFF00_0000 | (r8 << 16) | (g8 << 8) | b8
    }

    /// Rebuilds the cached colour tables: [0..<32] CGB background, [64..<96] CGB sprites.
    func rebuildPaletteCache() {
        paletteDirty = false
        for i in 0..<32 {
            colorLUT[i] = cgbColor(bgPalRAM, i)
            colorLUT[64 + i] = cgbColor(objPalRAM, i)
        }
    }

    func renderScanline() {
        if paletteDirty { rebuildPaletteCache() }
        let row = frame + ly * 160
        let bgEnabled = lcdc & 0x01 != 0

        if !isCGB {
            // DMG palettes for this line: [32..<36] background, [36..<40] OBP0, [40..<44] OBP1.
            for i in 0..<4 {
                colorLUT[32 + i] = dmgColors[Int((bgp >> UInt8(i * 2)) & 3)]
                colorLUT[36 + i] = dmgColors[Int((obp0 >> UInt8(i * 2)) & 3)]
                colorLUT[40 + i] = dmgColors[Int((obp1 >> UInt8(i * 2)) & 3)]
            }
            if !bgEnabled {          // LCDC bit 0 off blanks background and window on DMG
                let white = dmgColors[0]
                for x in 0..<160 {
                    lineBG[x] = 0
                    lineBGPrio[x] = false
                    row[x] = white
                }
                if lcdc & 0x02 != 0 { renderSprites(row) }
                return
            }
        }

        let winActive = lcdc & 0x20 != 0 && windowTriggered && Int(wx) < 167
        let winX0 = Int(wx) - 7
        var usedWindow = false
        let bgMapBase = lcdc & 0x08 != 0 ? 0x1C00 : 0x1800
        let winMapBase = lcdc & 0x40 != 0 ? 0x1C00 : 0x1800
        let unsignedTiles = lcdc & 0x10 != 0

        var x = 0
        while x < 160 {
            let inWindow = winActive && x >= winX0
            let mx: Int, my: Int, mapBase: Int
            if inWindow {
                mx = x - winX0
                my = windowLine
                mapBase = winMapBase
                usedWindow = true
            } else {
                mx = (Int(scx) + x) & 0xFF
                my = (Int(scy) + ly) & 0xFF
                mapBase = bgMapBase
            }
            let fx = mx & 7
            var run = min(8 - fx, 160 - x)
            if !inWindow && winActive && winX0 > x { run = min(run, winX0 - x) }   // window starts mid-tile

            let mapAddr = mapBase + (my >> 3) * 32 + (mx >> 3)
            let tile = vram[mapAddr]
            let attr: UInt8 = isCGB ? vram[0x2000 + mapAddr] : 0
            var fy = my & 7
            if attr & 0x40 != 0 { fy = 7 - fy }
            let dataOffset = unsignedTiles ? Int(tile) * 16 : 0x1000 + Int(Int8(bitPattern: tile)) * 16
            let bankOffset = attr & 0x08 != 0 ? 0x2000 : 0
            let lo = vram[bankOffset + dataOffset + fy * 2]
            let hi = vram[bankOffset + dataOffset + fy * 2 + 1]
            let flipX = attr & 0x20 != 0
            let prio = isCGB && attr & 0x80 != 0
            let lutBase = isCGB ? Int(attr & 7) * 4 : 32

            for k in 0..<run {
                let bit = UInt8(flipX ? fx + k : 7 - (fx + k))
                let idx = Int((hi >> bit) & 1) << 1 | Int((lo >> bit) & 1)
                lineBG[x + k] = UInt8(idx)
                lineBGPrio[x + k] = prio
                row[x + k] = colorLUT[lutBase + idx]
            }
            x += run
        }
        if usedWindow { windowLine += 1 }

        if lcdc & 0x02 != 0 { renderSprites(row) }
    }

    func renderSprites(_ row: UnsafeMutablePointer<UInt32>) {
        let height = lcdc & 0x04 != 0 ? 16 : 8
        // Select up to 10 sprites on this line in OAM order.
        var picked = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        withUnsafeMutableBytes(of: &picked) { raw in
            let list = raw.bindMemory(to: Int.self)
            for i in 0..<40 where count < 10 {
                let y = Int(oam[i * 4]) - 16
                if ly >= y && ly < y + height {
                    list[count] = i
                    count += 1
                }
            }
            // DMG: lower X wins, ties by OAM index. CGB: OAM index only (already in order).
            if !isCGB || opri & 1 != 0 {
                for i in 1..<max(count, 1) {
                    var j = i
                    while j > 0 {
                        let xa = Int(oam[list[j - 1] * 4 + 1]), xb = Int(oam[list[j] * 4 + 1])
                        if xb < xa {
                            let t = list[j - 1]; list[j - 1] = list[j]; list[j] = t
                            j -= 1
                        } else { break }
                    }
                }
            }
            for x in 0..<160 { lineClaimed[x] = false }
            for k in 0..<count {
                let base = list[k] * 4
                let sy = Int(oam[base]) - 16
                let sx = Int(oam[base + 1]) - 8
                var tile = Int(oam[base + 2])
                let attr = oam[base + 3]
                var fy = ly - sy
                if attr & 0x40 != 0 { fy = height - 1 - fy }
                if height == 16 { tile &= 0xFE }
                let bankOffset = isCGB && attr & 0x08 != 0 ? 0x2000 : 0
                let addr = bankOffset + tile * 16 + fy * 2
                let lo = vram[addr], hi = vram[addr + 1]
                for px in 0..<8 {
                    let x = sx + px
                    if x < 0 || x >= 160 || lineClaimed[x] { continue }
                    let bit = attr & 0x20 != 0 ? px : 7 - px
                    let idx = Int((hi >> UInt8(bit)) & 1) << 1 | Int((lo >> UInt8(bit)) & 1)
                    if idx == 0 { continue }
                    lineClaimed[x] = true
                    let bgWins: Bool
                    if isCGB && lcdc & 0x01 != 0 {
                        bgWins = lineBG[x] != 0 && (lineBGPrio[x] || attr & 0x80 != 0)
                    } else if !isCGB {
                        bgWins = attr & 0x80 != 0 && lineBG[x] != 0
                    } else {
                        bgWins = false
                    }
                    if bgWins { continue }
                    if isCGB {
                        row[x] = colorLUT[64 + Int(attr & 7) * 4 + idx]
                    } else {
                        row[x] = colorLUT[(attr & 0x10 != 0 ? 40 : 36) + idx]
                    }
                }
            }
        }
    }
}
