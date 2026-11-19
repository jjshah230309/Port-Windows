import Testing
@testable import GBACore

/// The gyro frame the data byte shifts out: six bytes that carry a six bit start value and
/// three twelve bit ADC channels.
private struct GyroFrame {
    let start: UInt8
    let x: UInt16
    let y: UInt16
    let z: UInt16

    init(bytes: [UInt8]) {
        // The frame is 48 bits, so it needs more room than a UInt32 gives.
        var frame: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            frame |= UInt64(byte) << UInt64(40 - 8 * index)
        }
        start = UInt8((frame >> 42) & 0x3F)
        x = UInt16((frame >> 30) & 0x0FFF)
        y = UInt16((frame >> 18) & 0x0FFF)
        z = UInt16((frame >> 6) & 0x0FFF)
    }
}

@Suite struct GBAGPIOTests {
    // MARK: Helpers

    /// Reads the six bytes of a gyro frame.
    private func readGyroFrame(_ gpio: GBAGPIO) -> [UInt8] {
        (0..<GBAGPIO.gyroFrameBytes).map { _ in gpio.read8(GBAGPIO.dataAddress) }
    }

    /// Writes the four bytes of the RTC's data area.
    private func writeRTC(_ gpio: GBAGPIO, _ time: GBAGPIO.RTCTime) {
        let word = GBAGPIO.packRTC(time)
        for index in 0..<4 {
            gpio.write8(GBAGPIO.dataAddress, UInt8((word >> UInt32(8 * index)) & 0xFF))
        }
    }

    // MARK: The gyro

    @Test func gyroReadsTheRestValueAtRest() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        #expect(gpio.peripheral == .gyro)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let frame = GyroFrame(bytes: readGyroFrame(gpio))
        #expect(frame.x == 0x6C0)
        #expect(frame.y == 0x6C0)
        #expect(frame.z == 0x6C0)
    }

    @Test func gyroReadsLargerWhenTurningClockwise() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        gpio.setRotation(x: 1.0)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let frame = GyroFrame(bytes: readGyroFrame(gpio))
        #expect(frame.x > 0x6C0)
        #expect(frame.x == 0x6C0 + 52)
    }

    @Test func gyroReadsSmallerWhenTurningTheOtherWay() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        gpio.setRotation(x: -1.0)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let frame = GyroFrame(bytes: readGyroFrame(gpio))
        #expect(frame.x < 0x6C0)
        #expect(frame.x == 0x6C0 - 52)
    }

    @Test func gyroClampsAtTheTopOfItsRange() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        gpio.setRotation(x: 100)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let frame = GyroFrame(bytes: readGyroFrame(gpio))
        #expect(frame.x == 4094)
    }

    @Test func gyroClampsAtTheBottomOfItsRange() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        gpio.setRotation(x: -100)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let frame = GyroFrame(bytes: readGyroFrame(gpio))
        #expect(frame.x == 1)
    }

    @Test func gyroFrameCarriesTheStartValueAndTheRightAlignment() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        gpio.setRotation(x: 1.0, y: -1.0)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let bytes = readGyroFrame(gpio)
        #expect(bytes.count == 6)
        // The start value sits in the top six bits of the first byte.
        #expect(bytes[0] >> 2 == 0b101010)
        // The X channel is twelve bits and straddles three bytes: its top two bits are the
        // bottom two bits of the first byte.
        #expect(bytes[0] & 0x03 == UInt8((0x6C0 + 52) >> 10 & 0x03))
        let frame = GyroFrame(bytes: bytes)
        #expect(frame.start == 0b101010)
        #expect(frame.x == 0x6C0 + 52)
        #expect(frame.y == 0x6C0 - 52)
        #expect(frame.z == 0x6C0)
    }

    @Test func gyroGivesTheSameFrameAfterANewConversion() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        gpio.setRotation(x: 0.5)
        gpio.write8(GBAGPIO.controlAddress, 0)
        let first = readGyroFrame(gpio)
        gpio.write8(GBAGPIO.controlAddress, 0)
        #expect(readGyroFrame(gpio) == first)
    }

    // MARK: The real-time clock

    @Test func rtcRegistersReadBackWhatWasWritten() {
        let gpio = GBAGPIO(gameCode: "PJEJ")
        #expect(gpio.peripheral == .realTimeClock)
        let time = GBAGPIO.RTCTime(seconds: 30, minutes: 45, hours: 12,
                                   day: 15, weekday: 3, month: 6, year: 2)
        writeRTC(gpio, time)
        let word = GBAGPIO.packRTC(time)
        for index in 0..<4 {
            #expect(gpio.read8(GBAGPIO.dataAddress) == UInt8((word >> UInt32(8 * index)) & 0xFF))
        }
        #expect(gpio.rtcTime.seconds == 30)
        #expect(gpio.rtcTime.minutes == 45)
        #expect(gpio.rtcTime.hours == 12)
        #expect(gpio.rtcTime.day == 15)
        #expect(gpio.rtcTime.weekday == 3)
        #expect(gpio.rtcTime.month == 6)
        #expect(gpio.rtcTime.year == 2)
    }

    @Test func rtcHaltBitStopsTheCounter() {
        let gpio = GBAGPIO(gameCode: "PJEJ")
        gpio.write8(GBAGPIO.controlAddress, GBAGPIO.controlHalt)
        #expect(gpio.rtcIsHalted)
        gpio.advance(seconds: 30)
        #expect(gpio.rtcTime.seconds == 0)
        gpio.write8(GBAGPIO.controlAddress, 0)
        #expect(!gpio.rtcIsHalted)
        gpio.advance(seconds: 30)
        #expect(gpio.rtcTime.seconds == 30)
    }

    @Test func rtcDayCounterRollsOverAfterFourYears() {
        let gpio = GBAGPIO(gameCode: "PJEJ")
        writeRTC(gpio, GBAGPIO.RTCTime(day: 31, month: 12, year: 3))
        #expect(gpio.rtcTime.dayCount == 1459)
        gpio.advance(seconds: 86_400)
        #expect(gpio.rtcTime.dayCount == 0)
        #expect(gpio.rtcTime.year == 0)
        #expect(gpio.rtcTime.month == 1)
        #expect(gpio.rtcTime.day == 1)
    }

    @Test func rtcCountsTheDaysAsTheyPass() {
        let gpio = GBAGPIO(gameCode: "PJEJ")
        writeRTC(gpio, GBAGPIO.RTCTime(day: 1, month: 1, year: 0))
        #expect(gpio.rtcTime.dayCount == 0)
        gpio.advance(seconds: 3 * 86_400)
        #expect(gpio.rtcTime.dayCount == 3)
        #expect(gpio.rtcTime.day == 4)
    }

    @Test func rtcResetBitPutsTheCountersBack() {
        let gpio = GBAGPIO(gameCode: "PJEJ")
        writeRTC(gpio, GBAGPIO.RTCTime(seconds: 30, minutes: 45, hours: 12,
                                       day: 15, weekday: 3, month: 6, year: 2))
        gpio.write8(GBAGPIO.controlAddress, GBAGPIO.controlReset)
        #expect(gpio.rtcTime.seconds == 0)
        #expect(gpio.rtcTime.minutes == 0)
        #expect(gpio.rtcTime.hours == 0)
        #expect(gpio.rtcTime.dayCount == 0)
        // The reset bit clears itself.
        #expect(gpio.controlByte & GBAGPIO.controlReset == 0)
    }

    // MARK: The port itself

    @Test func directionByteDecidesWhichBitsCanBeRead() {
        let gpio = GBAGPIO(gameCode: "AXVE")
        #expect(gpio.peripheral == .none)
        gpio.write8(GBAGPIO.dataAddress, 0xA5)
        gpio.write8(GBAGPIO.directionAddress, 0x0F)
        #expect(gpio.read8(GBAGPIO.dataAddress) == 0x05)
        gpio.write8(GBAGPIO.directionAddress, 0xF0)
        #expect(gpio.read8(GBAGPIO.dataAddress) == 0xA0)
    }

    @Test func registerReadGivesTheDataTheDirectionAndTheControl() {
        let gpio = GBAGPIO(gameCode: "AXVE")
        gpio.write8(GBAGPIO.dataAddress, 0x5A)
        // Every bit an output, so the data byte comes back whole.
        gpio.write8(GBAGPIO.directionAddress, 0xFF)
        gpio.write8(GBAGPIO.controlAddress, 0x08)
        #expect(gpio.read32(GBAGPIO.registerAddress) == 0x0008_FF5A)
    }

    @Test func rumbleBitTurnsTheMotorOn() {
        let gpio = GBAGPIO(gameCode: "MORJ")
        #expect(gpio.peripheral == .rumble)
        #expect(gpio.hasRumbleMotor)
        #expect(!gpio.rumbleActive)
        gpio.write8(GBAGPIO.controlAddress, GBAGPIO.controlRumble)
        #expect(gpio.rumbleActive)
        gpio.write8(GBAGPIO.controlAddress, 0)
        #expect(!gpio.rumbleActive)
    }

    @Test func theGyroCartridgeAlsoHasARumbleMotor() {
        let gpio = GBAGPIO(gameCode: "RZWJ")
        #expect(gpio.hasRumbleMotor)
        gpio.write8(GBAGPIO.controlAddress, GBAGPIO.controlRumble)
        #expect(gpio.rumbleActive)
    }

    // MARK: The peripheral a game code asks for

    @Test func gameCodeSelectsThePeripheral() {
        #expect(GBAGPIO.peripheral(forGameCode: "RZWJ") == .gyro)
        #expect(GBAGPIO.peripheral(forGameCode: "KYGT") == .tilt)
        #expect(GBAGPIO.peripheral(forGameCode: "BOKJ") == .solar)
        #expect(GBAGPIO.peripheral(forGameCode: "PJEJ") == .realTimeClock)
        #expect(GBAGPIO.peripheral(forGameCode: "MORJ") == .rumble)
        #expect(GBAGPIO.peripheral(forGameCode: "AXVE") == .none)
    }

    @Test func aCartridgeCanBeToldWhichPeripheralItHas() {
        let gpio = GBAGPIO(gameCode: "AXVE", peripheral: .solar)
        #expect(gpio.peripheral == .solar)
        gpio.setLightLevel(120)
        #expect(gpio.read8(GBAGPIO.dataAddress) == 120)
    }

    // MARK: The tilt sensor

    @Test func tiltRestsAtItsIdleValue() {
        let gpio = GBAGPIO(gameCode: "KYGT")
        #expect(gpio.peripheral == .tilt)
        let word = gpio.tiltWord()
        #expect(word & 0x0FFF == 0x3A0)
        #expect((word >> 12) & 0x0FFF == 0x3A0)
    }

    @Test func tiltMovesWithGravity() {
        let gpio = GBAGPIO(gameCode: "KYGT")
        gpio.setGravity(x: 1.0)
        let word = gpio.tiltWord()
        #expect(word & 0x0FFF == UInt16(0x3A0 - 79))
        gpio.setGravity(y: 1.0)
        let other = gpio.tiltWord()
        #expect((other >> 12) & 0x0FFF == UInt16(0x3A0 + 79))
    }

    @Test func tiltShiftsItsFourBytesThroughTheDataByte() {
        let gpio = GBAGPIO(gameCode: "KYGT")
        gpio.setGravity(x: 1.0)
        let word = gpio.tiltWord()
        for index in 0..<4 {
            #expect(gpio.read8(GBAGPIO.dataAddress) == UInt8((word >> UInt32(8 * index)) & 0xFF))
        }
    }

    @Test func tiltRotationRegisterFollowsTheGravity() {
        let gpio = GBAGPIO(gameCode: "KYGT")
        // Lying flat, the rotation registers read zero.
        #expect(gpio.tiltValues().rotation == 0)
        // On its side, the roll reads forty five degrees.
        gpio.setGravity(x: 9.81, z: 9.81)
        gpio.write8(GBAGPIO.controlAddress, 0x01)
        #expect(gpio.tiltValues().rotation == 45)
    }

    // MARK: The solar sensor

    @Test func solarSensorGivesTheLightLevel() {
        let gpio = GBAGPIO(gameCode: "BOKJ")
        #expect(gpio.peripheral == .solar)
        gpio.setLightLevel(200)
        #expect(gpio.read8(GBAGPIO.dataAddress) == 200)
        gpio.setLightIntensity(1)
        #expect(gpio.read8(GBAGPIO.dataAddress) == 0xFF - 0x16)
    }
}
