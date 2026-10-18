import EmulatorKit

public enum GameBoyError: Error, Equatable {
    case invalidROM(String)
    case unsupportedMapper(UInt8)
}

enum MBCKind { case none, mbc1, mbc2, mbc3, mbc5 }

/// Game Boy / Game Boy Color core. One class holds all state so the hot loop touches plain stored properties
/// and raw memory only; behaviour is split across extensions (CPU, bus, PPU, APU, cartridge, timers).
public final class GameBoyCore: EmulatorCore {
    public static let info = SystemInfo(
        id: "gb", label: "8-bit handheld (.gb / .gbc)", width: 160, height: 144,
        fpsNumerator: 4_194_304, fpsDenominator: 70_224, audioRate: 48_000)

    // MARK: Configuration
    /// True when running in colour-hardware mode (CGB cartridges, or forced with option model=cgb).
    public let isCGB: Bool
    public let title: String
    let clock: any HostClock

    // MARK: Memory
    let rom: UnsafeMutablePointer<UInt8>
    let romBankCount: Int
    let cartRAM: UnsafeMutablePointer<UInt8>
    let cartRAMSize: Int
    let vram: UnsafeMutablePointer<UInt8>      // 2 banks x 0x2000
    let wram: UnsafeMutablePointer<UInt8>      // 8 banks x 0x1000
    let oam: UnsafeMutablePointer<UInt8>       // 0xA0
    let hram: UnsafeMutablePointer<UInt8>      // 0x80
    let frame: UnsafeMutablePointer<UInt32>    // 160 x 144, 0xAARRGGBB
    let bgPalRAM: UnsafeMutablePointer<UInt8>  // 64
    let objPalRAM: UnsafeMutablePointer<UInt8> // 64
    let audioBuf: UnsafeMutablePointer<Int16>
    let audioCapacity = 16_384
    var audioCount = 0

    // MARK: Cartridge / mapper
    let mbc: MBCKind
    let hasBattery: Bool
    let hasRTC: Bool
    let hasRumble: Bool
    var ramEnabled = false
    var romBank = 1
    var ramBank = 0
    var mbc1Mode = 0
    var mbc1Hi = 0
    var bank0Base = 0
    var bankXBase = 0x4000
    var ramBase = 0
    var ramDirty = false
    var rumbleOn = false
    var rumbleCycles = 0
    var lastRumble: Float = -1
    // MBC3 real-time clock
    var rtcBase: Int64 = 0
    var rtcHalted = false
    var rtcFrozen: Int64 = 0
    var rtcCarry = false
    var rtcSelect = 0
    var rtcLatchPrev: UInt8 = 0xFF
    var rtcLatched: [UInt8] = [0, 0, 0, 0, 0]

    // MARK: CPU
    var a: UInt8 = 0, f: UInt8 = 0, b: UInt8 = 0, c: UInt8 = 0
    var d: UInt8 = 0, e: UInt8 = 0, h: UInt8 = 0, l: UInt8 = 0
    var sp: UInt16 = 0, pc: UInt16 = 0
    var ime = false
    var eiPending = false
    var halted = false
    var haltBug = false
    var stopped = false

    // MARK: Debug hooks
    /// Set when the CPU executes `LD B,B` (opcode 0x40), the breakpoint Mooneye-style tests use to report a result.
    public internal(set) var hitLDBB = false
    public var debugRegisters: (b: UInt8, c: UInt8, d: UInt8, e: UInt8, h: UInt8, l: UInt8) { (b, c, d, e, h, l) }

    // MARK: Interrupts / timer / serial / joypad
    var ie: UInt8 = 0
    var iflag: UInt8 = 0xE1
    var divCounter: UInt16 = 0
    var tima: UInt8 = 0, tma: UInt8 = 0, tac: UInt8 = 0
    var timaReloadPending = false
    var timaJustReloaded = false
    var sb: UInt8 = 0, sc: UInt8 = 0
    var serialBits = 0
    var serialCounter = 0
    public var serialOutput: [UInt8] = []
    var p1Select: UInt8 = 0x30
    var joyButtons: UInt8 = 0
    var joyDpad: UInt8 = 0
    var inputLatched = false
    var inputSource: (any InputSource)?

    // MARK: DMA
    var oamDMAActive = false
    var oamDMADelay = 0
    var oamDMAIndex = 0
    var oamDMASource = 0
    var oamDMAPendingSource = 0
    let oamDMAStartDelay = 2
    var dmaReg: UInt8 = 0xFF
    var hdmaSource: UInt16 = 0
    var hdmaDest: UInt16 = 0
    var hdmaActive = false
    var hdmaHBlank = false
    var hdmaBlocks = 0
    var hdmaPending = false

    // MARK: CGB registers
    var doubleSpeed = false
    var speedArmed = false
    var vramBank = 0
    var wramBank = 1
    var bcps: UInt8 = 0
    var ocps: UInt8 = 0
    var opri: UInt8 = 0

    // MARK: PPU
    var lcdc: UInt8 = 0x91
    var statReg: UInt8 = 0
    var scy: UInt8 = 0, scx: UInt8 = 0
    var ly = 0
    var lyReg: UInt8 = 0
    var lyc: UInt8 = 0
    var bgp: UInt8 = 0xFC, obp0: UInt8 = 0xFF, obp1: UInt8 = 0xFF
    var wy: UInt8 = 0, wx: UInt8 = 0
    var lcdOn = true
    var ppuMode = 1
    var ppuDot = 0
    var ppuEvent = 0
    var mode3Length = 172
    var statLine = false
    var lycFlag = false
    var windowLine = 0
    var windowTriggered = false
    var firstLineAfterEnable = false
    var lcdOffDots = 0
    var frameDone = false
    var dmgColors: [UInt32] = [0xFFFF_FFFF, 0xFFAA_AAAA, 0xFF55_5555, 0xFF00_0000]
    // per-scanline scratch
    let lineBG: UnsafeMutablePointer<UInt8>      // colour index 0-3 per pixel
    let lineBGPrio: UnsafeMutablePointer<Bool>   // CGB BG-over-sprite attribute
    let lineClaimed: UnsafeMutablePointer<Bool>
    let colorLUT: UnsafeMutablePointer<UInt32>   // cached palette colours, see rebuildPaletteCache()
    var paletteDirty = true

    // MARK: APU
    var apu = APUState()
    let apuRegs: UnsafeMutablePointer<UInt8>     // 0x30 bytes, FF10-FF3F raw storage (wave RAM at 0x20)
    var apuSamplePhase = 0
    var apuAccumL = 0
    var apuAccumR = 0
    var apuAccumCount = 0
    var apuMixL = 0
    var apuMixR = 0
    var apuMixDirty = true

    public init(media: MediaSource, firmware: FirmwareSet, options: CoreOptions, clock: any HostClock) throws {
        guard case .rom(let data) = media else { throw GameBoyError.invalidROM("expected a ROM image") }
        guard data.count >= 0x150 else { throw GameBoyError.invalidROM("file is smaller than a cartridge header") }

        // Parse the header before allocating anything.
        let cartType = data[0x147]
        var kind: MBCKind
        var battery = false, rtc = false, rumble = false, hasRAMChip = false
        switch cartType {
        case 0x00: kind = .none
        case 0x01: kind = .mbc1
        case 0x02: kind = .mbc1; hasRAMChip = true
        case 0x03: kind = .mbc1; hasRAMChip = true; battery = true
        case 0x05: kind = .mbc2
        case 0x06: kind = .mbc2; battery = true
        case 0x08: kind = .none; hasRAMChip = true
        case 0x09: kind = .none; hasRAMChip = true; battery = true
        case 0x0F: kind = .mbc3; rtc = true; battery = true
        case 0x10: kind = .mbc3; rtc = true; hasRAMChip = true; battery = true
        case 0x11: kind = .mbc3
        case 0x12: kind = .mbc3; hasRAMChip = true
        case 0x13: kind = .mbc3; hasRAMChip = true; battery = true
        case 0x19: kind = .mbc5
        case 0x1A: kind = .mbc5; hasRAMChip = true
        case 0x1B: kind = .mbc5; hasRAMChip = true; battery = true
        case 0x1C: kind = .mbc5; rumble = true
        case 0x1D: kind = .mbc5; rumble = true; hasRAMChip = true
        case 0x1E: kind = .mbc5; rumble = true; hasRAMChip = true; battery = true
        default: throw GameBoyError.unsupportedMapper(cartType)
        }
        var ramBytes = 0
        if kind == .mbc2 {
            ramBytes = 512
        } else if hasRAMChip {
            switch data[0x149] {
            case 1: ramBytes = 2048
            case 2: ramBytes = 8192
            case 3: ramBytes = 32768
            case 4: ramBytes = 131_072
            case 5: ramBytes = 65_536
            default: ramBytes = 0
            }
        }
        var banks = 2
        while banks * 0x4000 < data.count { banks <<= 1 }

        let cgbFlag = data[0x143]
        let model = options.values["model"] ?? "auto"
        isCGB = model == "cgb" || (model == "auto" && (cgbFlag & 0x80) != 0)
        title = String(decoding: data[0x134..<0x13F].prefix { $0 != 0 }, as: UTF8.self)
        self.clock = clock
        mbc = kind
        hasBattery = battery
        hasRTC = rtc
        hasRumble = rumble
        romBankCount = banks

        let romPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: banks * 0x4000)
        romPtr.initialize(repeating: 0xFF, count: banks * 0x4000)
        for i in 0..<min(data.count, banks * 0x4000) { romPtr[i] = data[i] }
        rom = romPtr
        cartRAMSize = ramBytes
        cartRAM = .allocate(capacity: max(ramBytes, 1))
        cartRAM.initialize(repeating: kind == .mbc2 ? 0xF0 : 0x00, count: max(ramBytes, 1))
        vram = .allocate(capacity: 0x4000); vram.initialize(repeating: 0, count: 0x4000)
        wram = .allocate(capacity: 0x8000); wram.initialize(repeating: 0, count: 0x8000)
        oam = .allocate(capacity: 0xA0); oam.initialize(repeating: 0, count: 0xA0)
        hram = .allocate(capacity: 0x80); hram.initialize(repeating: 0, count: 0x80)
        frame = .allocate(capacity: 160 * 144); frame.initialize(repeating: 0xFFFF_FFFF, count: 160 * 144)
        bgPalRAM = .allocate(capacity: 64); bgPalRAM.initialize(repeating: 0xFF, count: 64)
        objPalRAM = .allocate(capacity: 64); objPalRAM.initialize(repeating: 0xFF, count: 64)
        audioBuf = .allocate(capacity: 16_384); audioBuf.initialize(repeating: 0, count: 16_384)
        lineBG = .allocate(capacity: 160); lineBG.initialize(repeating: 0, count: 160)
        lineBGPrio = .allocate(capacity: 160); lineBGPrio.initialize(repeating: false, count: 160)
        lineClaimed = .allocate(capacity: 160); lineClaimed.initialize(repeating: false, count: 160)
        apuRegs = .allocate(capacity: 0x30); apuRegs.initialize(repeating: 0, count: 0x30)
        colorLUT = .allocate(capacity: 96); colorLUT.initialize(repeating: 0xFFFF_FFFF, count: 96)

        if options.values["palette"] == "green" {
            dmgColors = [0xFFE0_F8D0, 0xFF88_C070, 0xFF34_6856, 0xFF08_1820]
        }
        rtcBase = clock.unixSeconds()
        updateBanks()
        applyPostBootState()
    }

    deinit {
        rom.deallocate(); cartRAM.deallocate(); vram.deallocate(); wram.deallocate()
        oam.deallocate(); hram.deallocate(); frame.deallocate(); bgPalRAM.deallocate()
        objPalRAM.deallocate(); audioBuf.deallocate(); lineBG.deallocate()
        lineBGPrio.deallocate(); lineClaimed.deallocate(); apuRegs.deallocate(); colorLUT.deallocate()
    }

    // MARK: EmulatorCore

    public func reset(hard: Bool) {
        if hard {
            for i in 0..<0x4000 { vram[i] = 0 }
            for i in 0..<0x8000 { wram[i] = 0 }
        }
        ramEnabled = false; romBank = 1; ramBank = 0; mbc1Mode = 0; mbc1Hi = 0
        updateBanks()
        applyPostBootState()
    }

    public func runFrame(input: any InputSource, output: any OutputSink) {
        inputSource = input
        inputLatched = false
        frameDone = false
        rumbleCycles = 0
        var cyclesRun = 0
        while !frameDone {
            step()
            cyclesRun &+= 1
            if cyclesRun > 400_000 { break }   // safety valve; a frame is ~17,556 M-cycles
        }
        if !inputLatched { latchInput() }
        inputSource = nil
        if hasRumble {
            let duty = Float(rumbleCycles) / 17_556
            let s = min(max(duty, 0), 1)
            if s != lastRumble {
                lastRumble = s
                output.setRumble(port: 0, low: s, high: s)
            }
        }
    }

    public var video: VideoFrame {
        VideoFrame(pixels: UnsafeRawPointer(frame), width: 160, height: 144, pitch: 160 * 4, format: .bgra8)
    }

    public func drainAudio(_ sink: (UnsafeBufferPointer<Int16>) -> Void) {
        sink(UnsafeBufferPointer(start: audioBuf, count: audioCount))
        audioCount = 0
    }

    // MARK: Post-boot state (no boot ROM needed)

    func applyPostBootState() {
        if isCGB {
            a = 0x11; f = 0x80; b = 0x00; c = 0x00; d = 0xFF; e = 0x56; h = 0x00; l = 0x0D
        } else {
            a = 0x01; f = 0xB0; b = 0x00; c = 0x13; d = 0x00; e = 0xD8; h = 0x01; l = 0x4D
        }
        sp = 0xFFFE; pc = 0x0100
        ime = false; eiPending = false; halted = false; haltBug = false; stopped = false
        ie = 0x00; iflag = 0xE1
        divCounter = isCGB ? 0x1EA0 : 0xABCC
        tima = 0; tma = 0; tac = 0xF8; timaReloadPending = false
        sb = 0; sc = isCGB ? 0x7F : 0x7E; serialBits = 0; serialCounter = 0
        p1Select = 0x30
        lcdc = 0x91; statReg = 0; scy = 0; scx = 0; lyc = 0
        bgp = 0xFC; obp0 = 0xFF; obp1 = 0xFF; wy = 0; wx = 0
        lcdOn = true; ppuMode = 1; ly = 153; lyReg = 0; ppuDot = 400; ppuEvent = 2
        statLine = false; lycFlag = false; windowLine = 0; windowTriggered = false
        doubleSpeed = false; speedArmed = false; vramBank = 0; wramBank = 1; opri = 0
        oamDMAActive = false; hdmaActive = false; hdmaPending = false
        dmaReg = 0xFF
        apuPowerOnDefaults()
    }
}
