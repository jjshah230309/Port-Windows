// The Game Boy Advance's battery-backed save memory.
//
// Three kinds of save medium turn up inside GBA cartridges:
//
//   * Plain SRAM: a flat array of bytes. The game picks an address and writes a byte.
//   * EEPROM: a serial chip. The game writes a request into the save window and reads the
//     answer back out of it, a bit at a time or a nibble at a time.
//   * Flash: a serial chip as well, but with a command interface. The game writes an unlock
//     sequence, then a command, then the data.
//
// The window is the 64 KiB at 0A000000h-0A00FFFFh. This class is handed the offset of the
// address within that window, so offset 0 is the first byte of the save memory and offset
// 0xD000 is where a flash chip's status register lives.
//
// The address decoding depends on the size of the medium, so the mapping is not a plain
// index:
//
//   * SRAM mirrors: a 32 KiB chip answers the whole window with its 32 KiB twice.
//   * EEPROM ignores the address in the window. The address of the byte to read or write
//     travels inside the request the game writes into the window.
//   * Flash maps the window onto 32 KiB banks. The bank comes from the bank switch command
//     the game sends, or from the address itself on the chips that carry an ID byte.
//
// The flash commands follow GBATEK's "GBA Cart Backup Flash ROM" section: AAh to 5555h and
// 55h to 2AAAh unlock the chip, 90h enters the identification mode, 80h prepares an erase,
// 10h erases the whole chip, 30h erases the 4 KiB sector the command was written to, A0h
// arms a single byte write and B0h arms a bank switch.
//
// The EEPROM requests follow the drivers the games use: a word with 03h starts a write
// request, 02h starts a read request and 01h closes the request. The address follows, most
// significant bit first, under the dummy bits the chip wants on top of it.
//
// Detection is a heuristic, not a certainty. GBATEK's "GBA Cart Backup IDs" section names
// the ID strings Nintendo's tools put into a ROM ("EEPROM_Vnnn", "SRAM_Vnnn", "FLASH_Vnnn",
// "FLASH512_Vnnn", "FLASH1M_Vnnn"), and those settle the type when a ROM carries one.
// Failing that the ROM is searched for the strings of the flash chips ("SANYO", "MATSU",
// "TOSHIBA", "PANASONIC", "SAMSUNG" and friends) and for the opcode pattern of an EEPROM
// driver. Which chip a maker's string names is a guess: no published table gives it, and
// that rule is only a fallback for the ROMs that carry no ID string at all.
//
// The save window is reached from the bus rather than from the frame loop, so the storage
// stays an Array and every access takes the lock. docs/PLAN.md section 6 asks for raw
// pointers in the hot loop; the save window is not in the hot loop and the host has to be
// able to hand the bytes over as an Array, so this is an exemption from that rule.

import Synchronization

public final class GBASaveMedia: Sendable {

    // MARK: The kinds of save medium

    /// The save medium a cartridge carries.
    public enum Kind: Sendable, Equatable {
        /// No save memory: the window reads as open bus and writes go nowhere.
        case none
        /// Plain SRAM of the given number of bytes.
        case sram(bytes: Int)
        /// EEPROM of the given size.
        case eeprom(size: EEPROMSize)
        /// Flash of the given type.
        case flash(type: FlashType)
    }

    /// The EEPROM chips that turn up in GBA cartridges.
    public enum EEPROMSize: Sendable, Equatable, CaseIterable {
        /// 512 bytes (4 Kbit), the commonest chip.
        case bytes512
        /// 4 KiB (32 Kbit).
        case kib4
        /// 64 KiB (512 Kbit), a four bit chip.
        case kib64
        /// 128 KiB (1 Mbit), a four bit chip.
        case kib128
    }

    /// The flash chips that turn up in GBA cartridges.
    public enum FlashType: Sendable, Equatable, CaseIterable {
        /// 64 KiB, two banks of 32 KiB, with an ID byte at the start of the window.
        case flash64K
        /// 128 KiB, four banks of 32 KiB, with an ID byte at the start of the window.
        case flash128K
        /// 256 KiB, eight banks of 32 KiB.
        case flash256K
        /// 512 KiB, sixteen banks of 32 KiB.
        case flash512K
        /// 1 MiB, thirty two banks of 32 KiB.
        case flash1M
    }

    // MARK: The window

    /// The base address of the cartridge's save window.
    public static let windowBase: UInt32 = 0x0A00_0000
    /// The size of the cartridge's save window.
    public static let windowSize: UInt32 = 0x1_0000

    // MARK: State

    /// The mutable state of the save media. One lock, because the emulator core and the
    /// persistence code both reach for it.
    private struct State {
        var storage: [UInt8] = []
        var dirty = false

        // Flash.
        var bank = 0
        var bankSelected = false
        var command = FlashCommand.idle
        var unlock = FlashUnlock.none
        var idMode = false
        /// The manufacturer byte the chip answers with in the identification mode.
        var idMaker: UInt8 = 0
        /// The device byte the chip answers with in the identification mode.
        var idDevice: UInt8 = 0
        /// Whether the chip is in the middle of a program or an erase.
        var flashBusy = false

        // EEPROM.
        var eeprom = EEPROMState()
    }

    /// The flash command the chip is waiting for.
    private enum FlashCommand {
        case idle
        /// 80h has been written: the next command word erases.
        case erase
        /// A0h has been written: the next byte is programmed.
        case program
        /// B0h has been written: the next byte is the bank number.
        case bankSwitch
    }

    /// How far through the unlock sequence the chip is.
    private enum FlashUnlock {
        case none
        case first
        case second
    }

    /// The state of the EEPROM request the game is in the middle of.
    private struct EEPROMState {
        enum Phase {
            /// No request open.
            case idle
            /// Collecting the address.
            case address
            /// Collecting the data of a write request.
            case data
            /// Handing the data of a read request back.
            case readData
            /// The request is finished and waits for the word that closes it.
            case commit
        }

        var phase: Phase = .idle
        var isWrite = false
        /// The address of the request, accumulated most significant bit first.
        var address = 0
        /// The number of bits of the address phase that have come in.
        var bits = 0
        /// The data byte of a write request, as it comes in.
        var value: UInt8 = 0
        /// The number of bits of the answer that have been handed back.
        var readBit = 0
        /// Whether the chip is in the middle of its write cycle.
        var busy = false
    }

    private let state: Mutex<State>

    /// The kind of save medium this is.
    public let kind: Kind

    // MARK: Making save media

    /// Detects the save medium a ROM expects and sizes it.
    ///
    /// - Throws: `GBASaveMediaError.invalidROM` when the file holds nothing at all.
    public convenience init(rom: [UInt8]) throws {
        guard !rom.isEmpty else {
            throw GBASaveMediaError.invalidROM("the file is empty")
        }
        let found = Self.detectMedia(rom: rom)
        self.init(kind: found.kind)
        // The chip the ROM names gives the ID bytes, but only when the kind the detection
        // settled on is that chip's own: a RAM size code can turn a 64 KiB chip into a
        // 256 KiB one, and then the ID of the 256 KiB chip is the one that applies.
        if case .flash(let type) = found.kind, let chip = found.chip, chip.type == type {
            state.withLock {
                $0.idMaker = chip.id
                $0.idDevice = chip.device
            }
        }
    }

    /// Makes save media of a known kind, filled with 0xFF.
    public init(kind: Kind) {
        self.kind = kind
        var state = State(storage: [UInt8](repeating: 0xFF, count: kind.byteCount))
        if case .flash(let type) = kind {
            // The ID bytes belong to the chip, so a media made for a flash type carries
            // them even when no ROM was read.
            state.idMaker = type.idBytes.maker
            state.idDevice = type.idBytes.device
        }
        self.state = Mutex(state)
    }

    /// Why a ROM cannot be turned into save media.
    public enum GBASaveMediaError: Error, Equatable {
        /// The file holds nothing to look at.
        case invalidROM(String)
    }

    // MARK: The bytes the host persists

    /// The bytes of the save memory, the ones the host writes to disk.
    public var bytes: [UInt8] {
        state.withLock { $0.storage }
    }

    /// Whether the save memory has changed since the host last wrote it out.
    public var isDirty: Bool {
        state.withLock { $0.dirty }
    }

    /// The number of bytes the save memory holds.
    public var capacity: Int {
        kind.byteCount
    }

    /// Says the host has written the save memory out.
    public func markSaved() {
        state.withLock { $0.dirty = false }
    }

    /// Puts back the bytes the host read from disk.
    ///
    /// The content is truncated or padded to the size of the save memory, and the media comes
    /// back clean because the bytes on disk are what is now in it. The state of the chip goes
    /// with the old content: a command that was half done, a bank that was selected and the
    /// identification mode are all gone.
    public func restore(from bytes: [UInt8]) {
        state.withLock { state in
            let count = min(bytes.count, state.storage.count)
            for i in 0..<count { state.storage[i] = bytes[i] }
            if bytes.count < state.storage.count {
                for i in bytes.count..<state.storage.count { state.storage[i] = 0xFF }
            }
            state.dirty = false
            state.command = .idle
            state.unlock = .none
            state.bank = 0
            state.bankSelected = false
            state.idMode = false
            state.flashBusy = false
            state.eeprom = EEPROMState()
        }
    }

    // MARK: The address map

    /// The index in `bytes` that an address in the save window maps to.
    ///
    /// The mapping depends on the medium: SRAM mirrors its window, an EEPROM has no window
    /// address at all (the address of a byte travels inside the request the game writes, so
    /// there is no index to name) and flash maps the window onto the 32 KiB bank that is
    /// selected.
    public func storageIndex(for address: UInt32) -> Int? {
        state.withLock { state in
            switch kind {
            case .none:
                return nil
            case .sram(let size):
                let index = Int(address) & (size - 1)
                return index < state.storage.count ? index : nil
            case .eeprom:
                // The window address means nothing for an EEPROM.
                return nil
            case .flash(let type):
                let bank = bank(for: address, type: type, state: state)
                let index = bank * Self.bankBytes + (Int(address) & (Self.bankBytes - 1))
                return index < state.storage.count ? index : nil
            }
        }
    }

    // MARK: Reading and writing

    /// Reads a byte from the save window.
    ///
    /// The address is the offset within the window, so 0 is the first byte of the save
    /// memory and 0xD000 is the flash status register.
    @inline(__always)
    public func read(_ address: UInt32) -> UInt8 {
        state.withLock { state in
            switch kind {
            case .none:
                return 0xFF
            case .sram(let size):
                let index = Int(address) & (size - 1)
                return index < state.storage.count ? state.storage[index] : 0xFF
            case .eeprom(let size):
                return readEEPROM(size, &state)
            case .flash(let type):
                return readFlash(type, address, &state)
            }
        }
    }

    /// Writes a byte to the save window.
    ///
    /// The address is the offset within the window, as for `read`.
    @inline(__always)
    public func write(_ address: UInt32, _ value: UInt8) {
        state.withLock { state in
            switch kind {
            case .none:
                return
            case .sram(let size):
                let index = Int(address) & (size - 1)
                guard index < state.storage.count else { return }
                if state.storage[index] != value {
                    state.storage[index] = value
                    state.dirty = true
                }
            case .eeprom(let size):
                writeEEPROM(size, value, &state)
            case .flash(let type):
                writeFlash(type, address, value, &state)
            }
        }
    }

    // MARK: Plain SRAM

    // MARK: EEPROM

    /// Reads a byte out of the EEPROM, handing back the bits of the byte the request asked
    /// for.
    ///
    /// A chip that is in the middle of its write cycle holds the line low, so the read
    /// answers 00h until the request is closed; once the chip is ready it answers FFh,
    /// which is the bit a game polls for.
    private func readEEPROM(_ size: EEPROMSize, _ state: inout State) -> UInt8 {
        guard state.eeprom.phase == .readData else {
            return state.eeprom.busy ? 0x00 : 0xFF
        }
        let index = state.eeprom.address & (size.byteCount - 1)
        let byte = index < state.storage.count ? state.storage[index] : 0xFF
        var out: UInt8 = 0
        for i in 0..<size.bitsPerAccess {
            let bit = (byte >> UInt8(state.eeprom.readBit)) & 1
            out |= bit << UInt8(i)
            state.eeprom.readBit += 1
        }
        if state.eeprom.readBit >= 8 { state.eeprom.phase = .commit }
        return out
    }

    /// Writes to the EEPROM.
    ///
    /// The word written into the window carries the request: 03h starts a write request,
    /// 02h starts a read request, and 01h closes the request. In the one bit chips only the
    /// lowest bit of the word is used, which gives the same answer, because the lowest bit
    /// of 03h is 1 and the lowest bit of 02h is 0.
    private func writeEEPROM(_ size: EEPROMSize, _ value: UInt8, _ state: inout State) {
        switch state.eeprom.phase {
        case .idle:
            // The request word is the one field the games put the low way round: the
            // request code sits in the low bits of the word, so those are the first bits
            // on the wire.
            let control = Int(value & ((1 << size.controlBits) - 1))
            let isWrite: Bool
            if size.bitsPerAccess == 4 {
                switch control {
                case 0b11: isWrite = true
                case 0b10: isWrite = false
                default:
                    // 00h and 01h are not requests, so a word like that is ignored.
                    return
                }
            } else {
                isWrite = control & 1 != 0
            }
            state.eeprom.isWrite = isWrite
            state.eeprom.phase = .address
            state.eeprom.address = 0
            // The rest of the request word carries the first of the dummy bits.
            state.eeprom.bits = size.bitsPerAccess - size.controlBits
        case .commit:
            // The word that closes the request also ends the write cycle.
            state.eeprom.phase = .idle
            state.eeprom.busy = false
        case .address, .data:
            pushEEPROMBits(size, value, &state)
        case .readData:
            break
        }
    }

    /// Pushes the bits of one access into the request the game is making.
    ///
    /// The address is clocked most significant bit first, which is the way the chips take
    /// it, and the data byte is clocked least significant bit first, which is the way the
    /// drivers send it.
    private func pushEEPROMBits(_ size: EEPROMSize, _ value: UInt8, _ state: inout State) {
        switch state.eeprom.phase {
        case .address:
            for i in 0..<size.bitsPerAccess {
                let bit = (value >> UInt8(size.bitsPerAccess - 1 - i)) & 1
                if state.eeprom.bits >= size.dummyBits,
                   state.eeprom.bits < size.dummyBits + size.addressBits {
                    state.eeprom.address = (state.eeprom.address << 1) | Int(bit)
                }
                state.eeprom.bits += 1
            }
            if state.eeprom.bits >= size.dummyBits + size.addressBits + size.paddingBits {
                state.eeprom.phase = state.eeprom.isWrite ? .data : .readData
                state.eeprom.bits = 0
            }
        case .data:
            for i in 0..<size.bitsPerAccess {
                let bit = (value >> UInt8(i)) & 1
                state.eeprom.value |= bit << UInt8(state.eeprom.bits)
                state.eeprom.bits += 1
            }
            if state.eeprom.bits >= 8 {
                let index = state.eeprom.address & (size.byteCount - 1)
                if index < state.storage.count, state.storage[index] != state.eeprom.value {
                    state.storage[index] = state.eeprom.value
                    state.dirty = true
                }
                state.eeprom.value = 0
                state.eeprom.bits = 0
                // The chip is busy until the word that closes the request comes.
                state.eeprom.busy = true
                state.eeprom.phase = .commit
            }
        case .idle, .readData, .commit:
            break
        }
    }

    // MARK: Flash

    /// The size of one flash bank.
    public static let bankBytes = 0x8000

    /// Reads from the flash.
    private func readFlash(_ type: FlashType, _ address: UInt32, _ state: inout State) -> UInt8 {
        let offset = Int(address)
        // The status registers of the two banks say whether the chip is ready.
        if offset == 0xD000 || offset == 0xE000 {
            let busy = state.flashBusy
            state.flashBusy = false
            return busy ? 0x00 : 0xFF
        }
        if state.idMode, type.hasIDByte {
            // In the identification mode the chip answers with its ID bytes: the
            // manufacturer at offset 0 and the device at offset 1.
            switch offset {
            case 0: return state.idMaker
            case 1: return state.idDevice
            default: return 0x00
            }
        }
        let bank = bank(for: address, type: type, state: state)
        let index = bank * Self.bankBytes + (offset & (Self.bankBytes - 1))
        return index < state.storage.count ? state.storage[index] : 0xFF
    }

    /// Writes to the flash.
    ///
    /// The command words go to fixed places in the window: AAh to 5555h and 55h to 2AAAh
    /// unlock the chip, 80h starts an erase, 10h erases the whole chip and 30h erases the
    /// 4 KiB sector the command was written to, 90h enters the identification mode, A0h
    /// starts a single byte write and B0h starts a bank switch.
    private func writeFlash(_ type: FlashType, _ address: UInt32, _ value: UInt8,
                            _ state: inout State) {
        let offset = Int(address)
        let register = offset & (Self.bankBytes - 1)
        if register == 0x5555 {
            switch value {
            case 0xAA:
                state.unlock = .first
                return
            case 0xF0:
                // F0h leaves the identification mode, and on the chips that have it it
                // ends a command that has timed out.
                state.idMode = false
                state.command = .idle
                return
            default:
                break
            }
            if state.unlock == .second {
                switch value {
                case 0x80:
                    state.command = .erase
                    return
                case 0x90:
                    state.idMode = type.hasIDByte
                    state.command = .idle
                    return
                case 0xA0:
                    state.command = .program
                    return
                case 0xB0:
                    state.command = .bankSwitch
                    return
                default:
                    break
                }
            }
        } else if register == 0x2AAA {
            if value == 0x55, state.unlock == .first {
                state.unlock = .second
            } else {
                state.unlock = .none
            }
            return
        }

        switch state.command {
        case .erase:
            if value == 0x10 {
                eraseChip(&state)
            } else if value == 0x30 {
                eraseSector(type, offset, &state)
            }
            state.command = .idle
            return
        case .program:
            // The byte is programmed where it is written, not where A0h was written.
            writeByte(type, offset, value, &state)
            state.command = .idle
            return
        case .bankSwitch:
            // The bank number goes to the register at the start of the window, and it is
            // the number itself, not data for the save memory.
            if offset == 0 {
                state.bank = Int(value) & (type.bankCount - 1)
                state.bankSelected = true
            }
            state.command = .idle
            return
        case .idle:
            // A plain write, which the chip only takes once it has been unlocked.
            if state.unlock == .second {
                writeByte(type, offset, value, &state)
            }
        }
    }

    /// Writes one byte of the save memory.
    private func writeByte(_ type: FlashType, _ offset: Int, _ value: UInt8,
                           _ state: inout State) {
        let bank = bank(for: UInt32(offset), type: type, state: state)
        let index = bank * Self.bankBytes + (offset & (Self.bankBytes - 1))
        guard index < state.storage.count else { return }
        if state.storage[index] != value {
            state.storage[index] = value
            state.dirty = true
        }
        // The chip is busy for a moment after a program.
        state.flashBusy = true
    }

    /// Erases the 4 KiB sector the address is in.
    private func eraseSector(_ type: FlashType, _ offset: Int, _ state: inout State) {
        let bank = bank(for: UInt32(offset), type: type, state: state)
        let sector = offset & ~(Self.sectorBytes - 1)
        let start = bank * Self.bankBytes + sector
        guard start < state.storage.count else { return }
        for i in start..<min(start + Self.sectorBytes, state.storage.count) {
            if state.storage[i] != 0xFF {
                state.storage[i] = 0xFF
                state.dirty = true
            }
        }
        state.flashBusy = true
    }

    /// Erases the whole chip.
    private func eraseChip(_ state: inout State) {
        for i in 0..<state.storage.count where state.storage[i] != 0xFF {
            state.storage[i] = 0xFF
            state.dirty = true
        }
        state.flashBusy = true
    }

    /// The size of an erase sector.
    public static let sectorBytes = 0x1000

    /// The bank an address is in.
    ///
    /// A bank switched chip uses the bank the last B0h command picked. A chip with an ID
    /// byte has no bank switch, so the address itself names the bank.
    private func bank(for address: UInt32, type: FlashType, state: State) -> Int {
        if state.bankSelected { return state.bank }
        return bankNumber(for: Int(address), type: type)
    }

    /// The bank a command address names.
    private func bankNumber(for offset: Int, type: FlashType) -> Int {
        (offset >> 15) & (type.bankCount - 1)
    }

    // MARK: Detection

    /// Works out the save medium a ROM expects.
    ///
    /// The heuristic is the one GBATEK's "GBA Cart Backup IDs" section describes: the ID
    /// strings Nintendo's tools put into a ROM settle the type, and the strings of the flash
    /// chips and the opcode pattern of an EEPROM driver are the fallbacks for the ROMs that
    /// carry no ID string.
    public static func detect(rom: [UInt8]) -> Kind {
        detectMedia(rom: rom).kind
    }

    /// The kind of save media a ROM expects, and the flash chip it names if it names one.
    ///
    /// The ROM is scanned once, so that a ROM which names a chip does not pay for two
    /// searches.
    static func detectMedia(rom: [UInt8]) -> (kind: Kind, chip: FlashChip?) {
        let ramCode = rom.count > 0xE2 ? Int(rom[0xE2]) : 0
        // The ID strings of Nintendo's tools (GBATEK, "GBA Cart Backup IDs").
        if contains(rom, "EEPROM_V") {
            return (.eeprom(size: eepromSize(forRAMCode: ramCode)), nil)
        }
        if contains(rom, "SRAM_V") {
            return (.sram(bytes: sramSize(forRAMCode: ramCode) ?? 32 * 1024), nil)
        }
        if contains(rom, "FLASH1M_V") {
            return (.flash(type: .flash128K), nil)
        }
        if contains(rom, "FLASH512_V") {
            return (.flash(type: .flash64K), nil)
        }
        if contains(rom, "FLASH_V") {
            return (.flash(type: .flash64K), nil)
        }
        // The strings the flash chips' makers print.
        if let chip = detectFlashChip(rom: rom) {
            return (.flash(type: flashType(for: chip, ramCode: ramCode)), chip)
        }
        if detectEEPROMDriver(rom: rom) {
            return (.eeprom(size: eepromSize(forRAMCode: ramCode)), nil)
        }
        if let size = sramSize(forRAMCode: ramCode) {
            return (.sram(bytes: size), nil)
        }
        return (.none, nil)
    }

    /// A flash chip, with the ID bytes it answers with in the identification mode.
    public struct FlashChip: Sendable, Equatable {
        /// The string the ROM carries.
        public let name: String
        /// The kind of chip the string names.
        public let type: FlashType
        /// The manufacturer byte, the one the chip answers with at offset 0.
        public let id: UInt8
        /// The device byte, the one the chip answers with at offset 1.
        public let device: UInt8
    }

    /// The flash chips the strings in a ROM name.
    ///
    /// Which chip a maker's string names is a guess: no published table gives it, so the
    /// list is the one the homebrew save type tools carry. The device bytes are the device
    /// types of the identification codes GBATEK's "GBA Cart Backup Flash ROM" section lists
    /// for the chips it knows.
    static let flashChips: [FlashChip] = [
        FlashChip(name: "SANYO", type: .flash64K, id: 0x32, device: 0x13),
        FlashChip(name: "MATSU", type: .flash128K, id: 0x62, device: 0x09),
        FlashChip(name: "TOSHIBA", type: .flash64K, id: 0x1B, device: 0x00),
        FlashChip(name: "PANASONIC", type: .flash64K, id: 0x1D, device: 0x1B),
        FlashChip(name: "SAMSUNG", type: .flash128K, id: 0x1E, device: 0x00),
        FlashChip(name: "HITACHI", type: .flash64K, id: 0x13, device: 0x00),
        FlashChip(name: "NEC", type: .flash64K, id: 0x03, device: 0x00),
        FlashChip(name: "DALLAS", type: .flash64K, id: 0x16, device: 0x00),
        FlashChip(name: "AT25F", type: .flash64K, id: 0x1F, device: 0x3D),
        FlashChip(name: "SST", type: .flash64K, id: 0xBF, device: 0xD4),
        FlashChip(name: "MX29", type: .flash64K, id: 0x13, device: 0x00),
    ]

    /// The flash chip a ROM names, if it names one.
    public static func detectFlashChip(rom: [UInt8]) -> FlashChip? {
        for chip in flashChips where contains(rom, chip.name) { return chip }
        return nil
    }

    /// The ID byte a flash chip answers with.
    public static func flashID(rom: [UInt8]) -> UInt8? {
        detectFlashChip(rom: rom)?.id
    }

    /// Whether a ROM holds the opcode pattern of an EEPROM driver.
    ///
    /// The drivers the games use write and read the EEPROM with the opcodes D8h and D9h, and
    /// the pair turns up close together in the driver. No published table says so, so this
    /// is a guess, and it is kept narrow on purpose: the two bytes have to sit within a few
    /// bytes of each other and past the ROM header, or the common opcode bytes D8h and D9h
    /// in unrelated code would turn a plain SRAM game into an EEPROM.
    public static func detectEEPROMDriver(rom: [UInt8]) -> Bool {
        let window = 8
        var lastWrite = -1
        for (index, byte) in rom.enumerated() {
            if index < 0xC0 { continue }
            if byte == 0xD8 {
                lastWrite = index
                continue
            }
            if byte == 0xD9, lastWrite >= 0, index - lastWrite <= window { return true }
        }
        return false
    }

    /// The EEPROM size a RAM size code names.
    public static func eepromSize(forRAMCode code: Int) -> EEPROMSize {
        switch code {
        case 0x04: return .kib128
        case 0x05: return .kib64
        case 0x02, 0x03: return .kib4
        default: return .bytes512
        }
    }

    /// The SRAM size a RAM size code names.
    public static func sramSize(forRAMCode code: Int) -> Int? {
        switch code {
        case 0x01: return 2 * 1024
        case 0x02: return 8 * 1024
        case 0x03: return 32 * 1024
        case 0x04: return 128 * 1024
        case 0x05: return 64 * 1024
        default: return nil
        }
    }

    /// The flash size a chip and a RAM size code together name.
    ///
    /// The codes above 05h are an extension of the header's own table, used by the tools
    /// that made the larger flash carts.
    public static func flashType(for chip: FlashChip, ramCode: Int) -> FlashType {
        switch ramCode {
        case 0x06: return .flash256K
        case 0x07: return .flash512K
        case 0x08: return .flash1M
        case 0x04: return .flash128K
        default: return chip.type
        }
    }

    /// Whether a file holds the given text.
    static func contains(_ rom: [UInt8], _ text: String) -> Bool {
        find(rom, Array(text.utf8)) != nil
    }

    /// The first place in the file the bytes turn up.
    static func find(_ rom: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= rom.count else { return nil }
        let last = rom.count - needle.count
        var i = 0
        while i <= last {
            if rom[i] == needle[0] {
                var j = 1
                while j < needle.count, rom[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - The sizes of the media

extension GBASaveMedia.Kind {
    /// The number of bytes the medium holds.
    public var byteCount: Int {
        switch self {
        case .none: return 0
        case .sram(let bytes): return bytes
        case .eeprom(let size): return size.byteCount
        case .flash(let type): return type.byteCount
        }
    }
}

extension GBASaveMedia.EEPROMSize {
    /// The number of bytes the chip holds.
    public var byteCount: Int {
        switch self {
        case .bytes512: return 512
        case .kib4: return 4 * 1024
        case .kib64: return 64 * 1024
        case .kib128: return 128 * 1024
        }
    }

    /// The width of the address the chip takes, in bits.
    ///
    /// The width covers the whole chip, so every byte of it can be reached.
    public var addressBits: Int {
        switch self {
        case .bytes512: return 9
        case .kib4: return 12
        case .kib64: return 16
        case .kib128: return 17
        }
    }

    /// The dummy bits the chip wants above the address.
    public var dummyBits: Int {
        switch self {
        case .bytes512, .kib4: return 1
        case .kib64: return 2
        case .kib128: return 3
        }
    }

    /// How many bits one access to the window carries.
    public var bitsPerAccess: Int {
        switch self {
        case .bytes512, .kib4: return 1
        case .kib64, .kib128: return 4
        }
    }

    /// The bits the request code takes.
    ///
    /// The four bit chips use two bits for the request, the one bit chips one.
    var controlBits: Int {
        bitsPerAccess == 4 ? 2 : 1
    }

    /// The bits that pad the address out to a whole access.
    ///
    /// The four bit chips take the address a nibble at a time, so the request, the dummy
    /// bits and the address are padded out to a multiple of four bits. The padding comes
    /// after the address and is thrown away.
    var paddingBits: Int {
        guard bitsPerAccess == 4 else { return 0 }
        let bits = controlBits + dummyBits + addressBits
        return (bitsPerAccess - bits % bitsPerAccess) % bitsPerAccess
    }
}

extension GBASaveMedia.FlashType {
    /// The number of bytes the chip holds.
    public var byteCount: Int {
        switch self {
        case .flash64K: return 64 * 1024
        case .flash128K: return 128 * 1024
        case .flash256K: return 256 * 1024
        case .flash512K: return 512 * 1024
        case .flash1M: return 1024 * 1024
        }
    }

    /// The number of banks of 32 KiB the chip holds.
    public var bankCount: Int {
        byteCount / GBASaveMedia.bankBytes
    }

    /// Whether the chip carries an ID byte at the start of the window.
    ///
    /// The 64 KiB and 128 KiB chips answer with their ID in the identification mode; the
    /// larger ones are recognised by the ROM header and have no ID of their own.
    public var hasIDByte: Bool {
        self == .flash64K || self == .flash128K
    }

    /// The ID bytes the chip answers with when no ROM has named it.
    public var idBytes: (maker: UInt8, device: UInt8) {
        switch self {
        case .flash64K: return (0x32, 0x13)
        case .flash128K: return (0x62, 0x09)
        case .flash256K, .flash512K, .flash1M: return (0x32, 0x13)
        }
    }
}
