import Testing

@testable import GBACore

/// The battery-backed save media of a GBA cartridge: the flash, the EEPROM and the plain
/// SRAM, and the way the type is worked out from the ROM.
///
/// The tests drive the chips the way the hardware does, with the sequences GBATEK's
/// "GBA Cart Backup Flash ROM" section gives, so that a mistake in the protocol shows up
/// here rather than in a game.
@Suite("GBASaveMedia")
struct GBASaveMediaTests {

    // MARK: ROMs to detect

    /// A ROM of the usual size with a string in it and a RAM size code in the header.
    private func rom(text: String? = nil, ramCode: UInt8 = 0) -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: 0x1000)
        rom[0xE2] = ramCode
        if let text {
            let bytes = Array(text.utf8)
            rom.replaceSubrange(0x100..<(0x100 + bytes.count), with: bytes)
        }
        return rom
    }

    /// A ROM with the opcode pattern an EEPROM driver leaves behind.
    private func eepromROM(ramCode: UInt8 = 0) -> [UInt8] {
        var rom = rom(ramCode: ramCode)
        rom[0x200] = 0xD8
        rom[0x201] = 0xD9
        return rom
    }

    // MARK: Flash helpers

    /// Unlocks the chip and programs one byte, the way the hardware does it: the command
    /// word goes to 5555h and the byte itself to the address it belongs to.
    private func program(_ media: GBASaveMedia, _ offset: UInt32, _ value: UInt8) {
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xA0)
        media.write(offset, value)
    }

    /// Unlocks the chip, picks a bank and programs one byte.
    ///
    /// The bank switch is a command word to 5555h followed by the bank number at 0000h.
    private func program(_ media: GBASaveMedia, _ offset: UInt32, _ value: UInt8, bank: Int) {
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xB0)
        media.write(0x0000, UInt8(bank))
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xA0)
        media.write(offset, value)
    }

    /// Erases the whole chip, the way the hardware does it.
    private func eraseChip(_ media: GBASaveMedia) {
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0x80)
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0x10)
    }

    /// Erases the 4 KiB sector the address is in, the way the hardware does it.
    private func eraseSector(_ media: GBASaveMedia, _ offset: UInt32) {
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0x80)
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(offset, 0x30)
    }

    /// Puts the chip into its identification mode.
    private func enterIDMode(_ media: GBASaveMedia) {
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0x90)
    }

    /// Takes the chip out of its identification mode.
    private func leaveIDMode(_ media: GBASaveMedia) {
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xF0)
    }

    // MARK: EEPROM helpers

    /// Runs an EEPROM request: the request word, the address under its dummy bits, and the
    /// data byte of a write request.
    ///
    /// The request code sits in the low bits of the request word, the address is clocked
    /// most significant bit first and the data byte least significant bit first.
    private func eepromRequest(_ media: GBASaveMedia, address: Int, value: UInt8?,
                               size: GBASaveMedia.EEPROMSize, write: Bool) {
        let controlBits = size.bitsPerAccess == 4 ? 2 : 1
        let spare = size.bitsPerAccess - controlBits

        // The request word, with the first of the dummy bits above the request code.
        var word: UInt8 = controlBits == 2 ? (write ? 0b11 : 0b10) : (write ? 1 : 0)
        word |= UInt8((1 << spare) - 1) << UInt8(controlBits)
        media.write(0, word)

        // The rest of the dummy bits and then the address, most significant bit first.
        var bits: [Int] = []
        for _ in 0..<(size.dummyBits - spare) { bits.append(1) }
        for i in stride(from: size.addressBits - 1, through: 0, by: -1) {
            bits.append((address >> i) & 1)
        }
        // The four bit chips take the address a nibble at a time, so the request is padded
        // out to a whole number of nibbles.
        while bits.count % size.bitsPerAccess != 0 { bits.append(0) }
        for chunk in stride(from: 0, to: bits.count, by: size.bitsPerAccess) {
            var packed: UInt8 = 0
            for i in 0..<size.bitsPerAccess {
                packed |= UInt8(bits[chunk + i]) << UInt8(size.bitsPerAccess - 1 - i)
            }
            media.write(0, packed)
        }

        // The data byte, least significant bit first.
        if let value {
            var data: [Int] = []
            for i in 0..<8 { data.append(Int((value >> UInt8(i)) & 1)) }
            for chunk in stride(from: 0, to: data.count, by: size.bitsPerAccess) {
                var packed: UInt8 = 0
                for i in 0..<size.bitsPerAccess {
                    packed |= UInt8(data[chunk + i]) << UInt8(i)
                }
                media.write(0, packed)
            }
        }
    }

    /// Runs a write request on an EEPROM and closes it.
    private func eepromWrite(_ media: GBASaveMedia, _ address: Int, _ value: UInt8,
                             size: GBASaveMedia.EEPROMSize) {
        eepromRequest(media, address: address, value: value, size: size, write: true)
        media.write(0, 0x01)
    }

    /// Runs a read request on an EEPROM and gives the byte back.
    private func eepromRead(_ media: GBASaveMedia, _ address: Int,
                            size: GBASaveMedia.EEPROMSize) -> UInt8 {
        eepromRequest(media, address: address, value: nil, size: size, write: false)
        var value: UInt8 = 0
        for i in 0..<(8 / size.bitsPerAccess) {
            let part = media.read(0) & UInt8((1 << size.bitsPerAccess) - 1)
            value |= part << UInt8(i * size.bitsPerAccess)
        }
        media.write(0, 0x01)
        return value
    }

    // MARK: Detection

    @Test("A ROM with the Sanyo string has 64 KiB of flash")
    func detectsSanyoFlash() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        #expect(media.kind == .flash(type: .flash64K))
        #expect(media.capacity == 64 * 1024)
    }

    @Test("A ROM with the Matsushita string has 128 KiB of flash")
    func detectsMatsuFlash() throws {
        let media = try GBASaveMedia(rom: rom(text: "MATSU"))
        #expect(media.kind == .flash(type: .flash128K))
        #expect(media.capacity == 128 * 1024)
    }

    @Test("A ROM with the Toshiba string and a big RAM code has 256 KiB of flash")
    func detectsToshibaFlash() throws {
        let media = try GBASaveMedia(rom: rom(text: "TOSHIBA", ramCode: 0x06))
        #expect(media.kind == .flash(type: .flash256K))
    }

    @Test("A ROM with the Panasonic string has flash")
    func detectsPanasonicFlash() throws {
        let media = try GBASaveMedia(rom: rom(text: "PANASONIC"))
        #expect(media.kind == .flash(type: .flash64K))
    }

    @Test("A ROM with the Samsung string has flash")
    func detectsSamsungFlash() throws {
        let media = try GBASaveMedia(rom: rom(text: "SAMSUNG"))
        #expect(media.kind == .flash(type: .flash128K))
    }

    @Test("A ROM with the EEPROM ID string has an EEPROM")
    func detectsEEPROMIDString() throws {
        let media = try GBASaveMedia(rom: rom(text: "EEPROM_V123"))
        #expect(media.kind == .eeprom(size: .bytes512))
    }

    @Test("A ROM with the SRAM ID string has plain SRAM")
    func detectsSRAMIDString() throws {
        let media = try GBASaveMedia(rom: rom(text: "SRAM_V123"))
        #expect(media.kind == .sram(bytes: 32 * 1024))
    }

    @Test("A ROM with the flash ID strings has flash")
    func detectsFlashIDStrings() throws {
        #expect(try GBASaveMedia(rom: rom(text: "FLASH_V123")).kind == .flash(type: .flash64K))
        #expect(try GBASaveMedia(rom: rom(text: "FLASH512_V123")).kind == .flash(type: .flash64K))
        #expect(try GBASaveMedia(rom: rom(text: "FLASH1M_V123")).kind == .flash(type: .flash128K))
    }

    @Test("A ROM with a big RAM code has the bigger flash")
    func detectsBigFlash() throws {
        #expect(try GBASaveMedia(rom: rom(text: "TOSHIBA", ramCode: 0x07)).kind
                == .flash(type: .flash512K))
        #expect(try GBASaveMedia(rom: rom(text: "TOSHIBA", ramCode: 0x08)).kind
                == .flash(type: .flash1M))
    }

    @Test("The flash types have the right number of banks")
    func countsFlashBanks() {
        #expect(GBASaveMedia.FlashType.flash64K.bankCount == 2)
        #expect(GBASaveMedia.FlashType.flash128K.bankCount == 4)
        #expect(GBASaveMedia.FlashType.flash256K.bankCount == 8)
        #expect(GBASaveMedia.FlashType.flash512K.bankCount == 16)
        #expect(GBASaveMedia.FlashType.flash1M.bankCount == 32)
    }

    @Test("A ROM with the EEPROM opcodes has an EEPROM")
    func detectsEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        #expect(media.kind == .eeprom(size: .bytes512))
        #expect(media.capacity == 512)
    }

    @Test("EEPROM opcodes that are far apart are not an EEPROM")
    func ignoresDistantEEPROMOpcodes() throws {
        var bytes = rom(ramCode: 0x03)
        bytes[0x200] = 0xD8
        bytes[0x400] = 0xD9
        let media = try GBASaveMedia(rom: bytes)
        #expect(media.kind == .sram(bytes: 32 * 1024))
    }

    @Test("A ROM with a RAM size code has plain SRAM")
    func detectsSRAM() throws {
        let media = try GBASaveMedia(rom: rom(ramCode: 0x03))
        #expect(media.kind == .sram(bytes: 32 * 1024))
    }

    @Test("A ROM with nothing to go on has no save media")
    func detectsNothing() throws {
        let media = try GBASaveMedia(rom: rom())
        #expect(media.kind == .none)
        #expect(media.capacity == 0)
    }

    @Test("An empty file is refused")
    func refusesEmptyROM() {
        #expect(throws: GBASaveMedia.GBASaveMediaError.self) {
            try GBASaveMedia(rom: [])
        }
    }

    // MARK: The window

    @Test("A window with no save media reads as open bus")
    func readsOpenBus() throws {
        let media = try GBASaveMedia(rom: rom())
        #expect(media.read(0) == 0xFF)
        #expect(media.read(0x1234) == 0xFF)
        media.write(0, 0x42)
        #expect(media.read(0) == 0xFF)
        #expect(media.isDirty == false)
    }

    @Test("Plain SRAM takes a byte and gives it back")
    func readsAndWritesSRAM() throws {
        let media = try GBASaveMedia(rom: rom(ramCode: 0x03))
        media.write(0x1234, 0x5A)
        #expect(media.read(0x1234) == 0x5A)
        #expect(media.isDirty)
    }

    @Test("Plain SRAM mirrors the window")
    func mirrorsSRAM() throws {
        let media = try GBASaveMedia(rom: rom(ramCode: 0x03))
        media.write(0x0010, 0x77)
        // The chip is 32 KiB, so the window answers twice over.
        #expect(media.read(0x8010) == 0x77)
    }

    @Test("The address map of plain SRAM")
    func mapsSRAM() throws {
        let media = try GBASaveMedia(rom: rom(ramCode: 0x03))
        #expect(media.storageIndex(for: 0x0000) == 0)
        #expect(media.storageIndex(for: 0x8000) == 0)
    }

    @Test("An EEPROM has no address in the window")
    func eepromHasNoWindowAddress() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        #expect(media.storageIndex(for: 0x0000) == nil)
        #expect(media.storageIndex(for: 0x1234) == nil)
    }

    // MARK: Flash

    @Test("Flash takes a byte and gives it back")
    func readsAndWritesFlash() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0100, 0x42)
        #expect(media.read(0x0100) == 0x42)
        #expect(media.isDirty)
    }

    @Test("A programmed byte lands where it is written")
    func programsAtTheTarget() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0123, 0x5A)
        #expect(media.read(0x0123) == 0x5A)
        // The command word's own address is not the target of the byte.
        #expect(media.read(0x5555) == 0xFF)
    }

    @Test("Flash takes a byte written straight into the window")
    func writesFlashDirectly() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x0200, 0x7E)
        #expect(media.read(0x0200) == 0x7E)
    }

    @Test("Erasing a flash sector leaves FF behind")
    func erasesFlashSector() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0100, 0x42)
        program(media, 0x0200, 0x43)
        eraseSector(media, 0x0100)
        #expect(media.read(0x0100) == 0xFF)
        // The whole 4 KiB sector goes, and 0200h is in that sector.
        #expect(media.read(0x0200) == 0xFF)
    }

    @Test("Erasing a flash sector leaves the other sectors alone")
    func erasesOnlyOneSector() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0100, 0x42)
        // 1100h is in the next 4 KiB sector, so it is not touched.
        program(media, 0x1100, 0x43)
        eraseSector(media, 0x0100)
        #expect(media.read(0x0100) == 0xFF)
        #expect(media.read(0x1100) == 0x43)
    }

    @Test("Erasing the whole flash leaves FF behind")
    func erasesFlashChip() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0100, 0x42)
        program(media, 0x8100, 0x43)
        eraseChip(media)
        #expect(media.read(0x0100) == 0xFF)
        #expect(media.read(0x8100) == 0xFF)
    }

    @Test("Switching flash banks leaves the other bank alone")
    func switchesFlashBanks() throws {
        let media = GBASaveMedia(kind: .flash(type: .flash256K))
        program(media, 0x0100, 0x11)
        program(media, 0x0200, 0x22, bank: 1)
        // The chip is still on bank one, so the first bank's byte is not in sight.
        #expect(media.read(0x0100) == 0xFF)
        #expect(media.read(0x0200) == 0x22)
        // Back to the first bank.
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xB0)
        media.write(0x0000, 0)
        #expect(media.read(0x0100) == 0x11)
        #expect(media.read(0x0200) == 0xFF)
    }

    @Test("The bank number is not written into the save memory")
    func bankNumberIsNotData() throws {
        let media = GBASaveMedia(kind: .flash(type: .flash256K))
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xB0)
        media.write(0x0000, 1)
        #expect(media.bytes[0] == 0xFF)
        #expect(media.bytes[0x8000] == 0xFF)
    }

    @Test("A bank number beyond the chip is masked to the banks it has")
    func masksBankNumber() throws {
        let media = GBASaveMedia(kind: .flash(type: .flash1M))
        // A chip with 32 banks takes a bank number of 0 to 31, so 33 is bank one.
        media.write(0x5555, 0xAA)
        media.write(0x2AAA, 0x55)
        media.write(0x5555, 0xB0)
        media.write(0x0000, 33)
        program(media, 0x0100, 0x77)
        #expect(media.bytes[0x8000 + 0x0100] == 0x77)
    }

    @Test("A flash chip answers with its ID in the identification mode")
    func readsFlashID() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        #expect(media.read(0) == 0xFF)
        enterIDMode(media)
        // The manufacturer byte is at offset 0 and the device byte at offset 1.
        #expect(media.read(0) == 0x32)
        #expect(media.read(1) == 0x13)
        leaveIDMode(media)
        #expect(media.read(0) == 0xFF)
    }

    @Test("A flash media made for a type carries that type's ID")
    func flashIDFollowsTheType() throws {
        let media = GBASaveMedia(kind: .flash(type: .flash64K))
        enterIDMode(media)
        #expect(media.read(0) == 0x32)
        #expect(media.read(1) == 0x13)
    }

    @Test("A ROM whose RAM size changes the flash size has no ID of the old chip")
    func flashIDFollowsTheDetectedKind() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO", ramCode: 0x06))
        #expect(media.kind == .flash(type: .flash256K))
        enterIDMode(media)
        // The 256 KiB chip has no ID of its own, so the window shows the save memory.
        #expect(media.read(0) == 0xFF)
    }

    @Test("The flash status registers say whether the chip is ready")
    func readsFlashStatus() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        #expect(media.read(0xD000) == 0xFF)
        #expect(media.read(0xE000) == 0xFF)
        program(media, 0x0100, 0x42)
        // The chip is busy for a moment after the program, and the status says so.
        #expect(media.read(0xD000) == 0x00)
        #expect(media.read(0xD000) == 0xFF)
    }

    @Test("A flash chip with an ID byte has its banks at the ends of the window")
    func banksFlashByAddress() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0100, 0x11)
        program(media, 0x8100, 0x22)
        #expect(media.read(0x0100) == 0x11)
        #expect(media.read(0x8100) == 0x22)
    }

    // MARK: EEPROM

    @Test("An EEPROM write request and a read request give the same byte back")
    func readsAndWritesEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        eepromWrite(media, 0x05, 0xA7, size: .bytes512)
        #expect(eepromRead(media, 0x05, size: .bytes512) == 0xA7)
        #expect(media.isDirty)
    }

    @Test("An EEPROM byte lands at the address the request asked for")
    func eepromLandsAtTheAddress() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        eepromWrite(media, 0x05, 0xA7, size: .bytes512)
        #expect(media.bytes[0x05] == 0xA7)
        #expect(media.bytes[0x0A] == 0xFF)
    }

    @Test("An EEPROM address is clocked most significant bit first")
    func eepromAddressIsMostSignificantFirst() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        eepromWrite(media, 0x05, 0xA7, size: .bytes512)
        // The same bits read the other way round would name the address 0A0h.
        #expect(media.bytes[0x05] == 0xA7)
        #expect(media.bytes[0xA0] == 0xFF)
    }

    @Test("An EEPROM read request gives a byte that was never written as FF")
    func readsBlankEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        #expect(eepromRead(media, 0x10, size: .bytes512) == 0xFF)
    }

    @Test("The whole of a 512 byte EEPROM can be reached")
    func reachesTopOf512ByteEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        eepromWrite(media, 0x1FF, 0x3C, size: .bytes512)
        #expect(media.bytes[0x1FF] == 0x3C)
        #expect(eepromRead(media, 0x1FF, size: .bytes512) == 0x3C)
    }

    @Test("A four bit EEPROM takes a byte and gives it back")
    func readsAndWritesFourBitEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM(ramCode: 0x05))
        #expect(media.kind == .eeprom(size: .kib64))
        eepromWrite(media, 0x1234, 0x5B, size: .kib64)
        #expect(media.bytes[0x1234] == 0x5B)
        #expect(eepromRead(media, 0x1234, size: .kib64) == 0x5B)
    }

    @Test("The whole of a 64 KiB EEPROM can be reached")
    func reachesTopOf64KiBEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM(ramCode: 0x05))
        eepromWrite(media, 0xFFFF, 0x77, size: .kib64)
        #expect(media.bytes[0xFFFF] == 0x77)
        #expect(eepromRead(media, 0xFFFF, size: .kib64) == 0x77)
    }

    @Test("An EEPROM with a 128 KiB size uses four dummy bits")
    func readsAndWritesBigEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM(ramCode: 0x04))
        #expect(media.kind == .eeprom(size: .kib128))
        eepromWrite(media, 0x4321, 0xC3, size: .kib128)
        #expect(media.bytes[0x4321] == 0xC3)
        #expect(eepromRead(media, 0x4321, size: .kib128) == 0xC3)
    }

    @Test("The whole of a 128 KiB EEPROM can be reached")
    func reachesTopOf128KiBEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM(ramCode: 0x04))
        eepromWrite(media, 0x1FFFF, 0x6E, size: .kib128)
        #expect(media.bytes[0x1FFFF] == 0x6E)
        #expect(eepromRead(media, 0x1FFFF, size: .kib128) == 0x6E)
    }

    @Test("An EEPROM with a 4 KiB size takes a byte")
    func readsAndWrites4KiBEEPROM() throws {
        let media = try GBASaveMedia(rom: eepromROM(ramCode: 0x02))
        #expect(media.kind == .eeprom(size: .kib4))
        eepromWrite(media, 0x0100, 0x3C, size: .kib4)
        #expect(media.bytes[0x0100] == 0x3C)
        #expect(eepromRead(media, 0x0100, size: .kib4) == 0x3C)
    }

    @Test("An EEPROM holds the line low while it writes")
    func eepromIsBusyWhileItWrites() throws {
        let media = try GBASaveMedia(rom: eepromROM())
        eepromRequest(media, address: 0x10, value: 0x5A, size: .bytes512, write: true)
        // The request is not closed yet, so the chip is still busy.
        #expect(media.read(0) == 0x00)
        // Closing the request ends the write cycle.
        media.write(0, 0x01)
        #expect(media.read(0) == 0xFF)
    }

    // MARK: The bytes the host persists

    @Test("The dirty flag is set by a write and cleared by marking the media saved")
    func marksSaved() throws {
        let media = try GBASaveMedia(rom: rom(ramCode: 0x03))
        #expect(media.isDirty == false)
        media.write(0x0010, 0x99)
        #expect(media.isDirty)
        media.markSaved()
        #expect(media.isDirty == false)
    }

    @Test("Putting the bytes back gives the same content")
    func restoresFromBytes() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        program(media, 0x0100, 0x42)
        let saved = media.bytes
        let other = try GBASaveMedia(rom: rom(text: "SANYO"))
        other.restore(from: saved)
        #expect(other.bytes == saved)
        #expect(other.read(0x0100) == 0x42)
        #expect(other.isDirty == false)
    }

    @Test("Putting the bytes back forgets the bank that was selected")
    func restoreResetsTheBank() throws {
        let media = GBASaveMedia(kind: .flash(type: .flash256K))
        program(media, 0x0100, 0x11, bank: 1)
        media.markSaved()
        media.restore(from: media.bytes)
        // The chip is back on the bank the address names.
        #expect(media.read(0x0100) == 0xFF)
        #expect(media.read(0x8100) == 0x11)
    }

    @Test("The bytes of a fresh chip are all FF")
    func startsBlank() throws {
        let media = try GBASaveMedia(rom: rom(text: "SANYO"))
        #expect(media.bytes.count == 64 * 1024)
        #expect(media.bytes.allSatisfy { $0 == 0xFF })
    }
}
