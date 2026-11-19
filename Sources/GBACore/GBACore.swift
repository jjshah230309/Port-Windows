import EmulatorKit

public enum GameBoyAdvanceError: Error, Equatable {
    case invalidROM(String)
}

/// Static description of the machine, kept for callers that only need the system's shape.
public enum GameBoyAdvance {
    public static let info = SystemInfo(
        id: "gba", label: "32-bit handheld (.gba)", width: 240, height: 160,
        fpsNumerator: 16_777_216, fpsDenominator: 280_896, audioRate: 48_000)
}

/// Game Boy Advance core. One class holds all state so the hot loop touches plain stored properties
/// and raw memory only; behaviour is split across extensions (bus, state).
///
/// The CPU and the PPU land in a later milestone: this file owns the machine's memory map, its
/// frame buffer and the save-state format, and `runFrame` advances the frame boundary without
/// executing any code yet.
public final class GameBoyAdvanceCore: EmulatorCore {
    public static let info = GameBoyAdvance.info

    // MARK: Configuration
    public let title: String
    public let gameCode: String
    public let makerCode: String
    let clock: any HostClock

    // MARK: Memory
    let bios: UnsafeMutablePointer<UInt8>       // 16 KiB, zero-filled when no BIOS is supplied
    let rom: UnsafeMutablePointer<UInt8>        // cartridge ROM, up to 32 MiB
    let romSize: Int
    let ewram: UnsafeMutablePointer<UInt8>       // 256 KiB, mirrored through the 16 MiB window
    let iwram: UnsafeMutablePointer<UInt8>       // 32 KiB, the first 0xC0 bytes are BIOS/system
    let ioRegs: UnsafeMutablePointer<UInt8>      // 1 KiB of I/O registers at 0x04000000
    let paletteRAM: UnsafeMutablePointer<UInt8>  // 1 KiB at 0x04000400
    let vram: UnsafeMutablePointer<UInt8>        // 96 KiB at 0x06000000
    let oam: UnsafeMutablePointer<UInt8>         // 1 KiB at 0x05000000, mirrored every 400h
    let gbWindow: UnsafeMutablePointer<UInt8>     // 16 KiB at 0x0E000000
    let soundRegs: UnsafeMutablePointer<UInt8>   // 1 KiB at 0x07000000
    let frame: UnsafeMutablePointer<UInt32>      // 240 x 160, 0xAARRGGBB
    // The audio buffer is empty until the sound hardware lands with the CPU; the core still has to
    // answer drainAudio, so the storage is here and the count stays at zero.
    let audioBuf: UnsafeMutablePointer<Int16>
    let audioCapacity = 16_384
    var audioCount = 0

    /// The sizes of the memory regions, kept next to the storage they describe.
    enum Size {
        static let ewram = 0x4_0000      // 256 KiB
        static let iwram = 0x8000        // 32 KiB
        static let vram = 0x1_8000       // 96 KiB
        static let oam = 0x400          // 1 KiB
        static let palette = 0x400      // 1 KiB
        static let ioRegs = 0x400       // 1 KiB
        static let sound = 0x400        // 1 KiB
    }

    // MARK: Frame timing
    /// The machine's cycle counter (16.78 MHz). The CPU will advance it; until then only the frame
    /// counter moves, by the number of cycles a frame lasts.
    var cycleCounter: UInt64 = 0
    var frameCounter: UInt64 = 0

    // MARK: Input
    var inputSource: (any InputSource)?
    var inputLatched = false
    /// KEYINPUT, active low: a pressed button reads 0.
    var keyInput: UInt16 = 0x03FF

    // MARK: Rumble
    var lastRumble: Float = -1

    public init(media: MediaSource, firmware: FirmwareSet, options: CoreOptions, clock: any HostClock) throws {
        guard case .rom(let data) = media else { throw GameBoyAdvanceError.invalidROM("expected a ROM image") }
        guard data.count >= 0xC0 else { throw GameBoyAdvanceError.invalidROM("file is smaller than a cartridge header") }

        // The cartridge layer owns the header (Sources/GBACore/GBACartridge.swift).
        let header = GBACartridgeInfo(rom: data)
        title = header.title
        gameCode = header.gameCode
        makerCode = header.makerCode
        self.clock = clock

        // Cartridge ROM: the header's size code wins over the file length, and the bus mirrors the
        // ROM window up to 32 MiB, so allocate what the header asks for and fill the rest with 0xFF.
        let romBytes = min(header.romBytes, 0x0200_0000)
        let romPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: max(romBytes, 0xC0))
        romPtr.initialize(repeating: 0xFF, count: max(romBytes, 0xC0))
        for i in 0..<min(data.count, romBytes) { romPtr[i] = data[i] }
        rom = romPtr
        romSize = max(romBytes, 0xC0)

        // BIOS: 16 KiB of storage. A missing BIOS is a zero-filled stand-in so the bus always has
        // somewhere to read from.
        let biosPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x4000)
        biosPtr.initialize(repeating: 0, count: 0x4000)
        if let bios = firmware.files["bios"] {
            for i in 0..<min(bios.count, 0x4000) { biosPtr[i] = bios[i] }
        }
        bios = biosPtr

        ewram = .allocate(capacity: Size.ewram); ewram.initialize(repeating: 0, count: Size.ewram)
        iwram = .allocate(capacity: Size.iwram); iwram.initialize(repeating: 0, count: Size.iwram)
        ioRegs = .allocate(capacity: Size.ioRegs); ioRegs.initialize(repeating: 0, count: Size.ioRegs)
        paletteRAM = .allocate(capacity: Size.palette); paletteRAM.initialize(repeating: 0, count: Size.palette)
        vram = .allocate(capacity: Size.vram); vram.initialize(repeating: 0, count: Size.vram)
        oam = .allocate(capacity: Size.oam); oam.initialize(repeating: 0, count: Size.oam)
        gbWindow = .allocate(capacity: 0x4000); gbWindow.initialize(repeating: 0, count: 0x4000)
        soundRegs = .allocate(capacity: Size.sound); soundRegs.initialize(repeating: 0, count: Size.sound)
        frame = .allocate(capacity: 240 * 160); frame.initialize(repeating: 0xFFFF_FFFF, count: 240 * 160)
        audioBuf = .allocate(capacity: 16_384); audioBuf.initialize(repeating: 0, count: 16_384)
    }

    deinit {
        bios.deallocate(); rom.deallocate(); ewram.deallocate(); iwram.deallocate()
        ioRegs.deallocate(); paletteRAM.deallocate(); vram.deallocate(); oam.deallocate()
        gbWindow.deallocate(); soundRegs.deallocate(); frame.deallocate(); audioBuf.deallocate()
    }

    // MARK: EmulatorCore

    public func reset(hard: Bool) {
        if hard {
            for i in 0..<Size.ewram { ewram[i] = 0 }
            for i in 0..<Size.iwram { iwram[i] = 0 }
            for i in 0..<Size.vram { vram[i] = 0 }
            for i in 0..<Size.oam { oam[i] = 0 }
            for i in 0..<Size.palette { paletteRAM[i] = 0 }
            for i in 0..<Size.ioRegs { ioRegs[i] = 0 }
            for i in 0..<Size.sound { soundRegs[i] = 0 }
            for i in 0..<0x4000 { gbWindow[i] = 0 }
        }
        cycleCounter = 0
        frameCounter = 0
        inputLatched = false
        keyInput = 0x03FF
        lastRumble = -1
    }

    public func runFrame(input: any InputSource, output: any OutputSink) {
        inputSource = input
        inputLatched = false

        // Placeholder frame: the CPU lands in a later task, so nothing executes yet. The frame
        // boundary still advances deterministically - one frame is 280,896 cycles of the 16.78 MHz
        // clock - and the frame counter is the only state that depends on it.
        cycleCounter &+= 280_896
        frameCounter &+= 1

        // Input is latched lazily, exactly like the Game Boy core: the guest reads the pad
        // registers through the bus, and that read pulls the snapshot in.
        if !inputLatched { latchInput() }
        inputSource = nil

        // The GBA has no rumble hardware of its own; rumble lives in the cartridge (the rumble
        // flash carts). There is none here, so the core reports "off" once and then stays quiet.
        if lastRumble != 0 {
            lastRumble = 0
            output.setRumble(port: 0, low: 0, high: 0)
        }
    }

    public var video: VideoFrame {
        VideoFrame(pixels: UnsafeRawPointer(frame), width: 240, height: 160, pitch: 240 * 4, format: .bgra8)
    }

    public func drainAudio(_ sink: (UnsafeBufferPointer<Int16>) -> Void) {
        sink(UnsafeBufferPointer(start: audioBuf, count: audioCount))
        audioCount = 0
    }

    // MARK: Battery save
    // No save support yet: the GBA's save media (EEPROM, flash, SRAM) belongs to the cartridge
    // layer, which is a later task. Until then there is nothing to write to disk.

    public var batterySave: BatterySave? { nil }

    public func markBatterySaved() {}

    public func loadBatterySave(_ bytes: [UInt8]) {}
}
