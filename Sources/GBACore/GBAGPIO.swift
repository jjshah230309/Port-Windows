// The Game Boy Advance cartridge GPIO port, 080000C4h-080000C8h.
//
// The port is what carries a cartridge's special hardware: the real-time clock, the gyro, the
// tilt sensor, the solar sensor and the rumble motor. Which of them a cartridge has is decided
// by its game code, so the port is built with the code and picks its peripheral from it.
//
// The register at 080000C4h is 32 bits wide and holds the three port bytes:
//
//   bits  0-7   data
//   bits  8-15  direction
//   bits 16-23  control
//   bits 24-31  unused
//
// The byte addresses follow the register: data at C4h, direction at C5h, control at C6h. GBATEK
// puts the control byte at C8h, so that address is taken as well.
//
// A peripheral with more than one byte to give (the RTC's date and time, the tilt's two axes)
// is a serial device: the guest reads the data byte over and over and the peripheral shifts a
// frame through it, one byte per read, exactly as it does with the S3511 clock on real
// hardware. The peripheral is a shift register, so the byte a read returns is the one the
// previous read prepared: the protocol reads the address twice to be sure the first byte has
// arrived.
//
// The control byte means different things to different peripherals:
//   bit 3   the rumble motor
//   bit 4   the RTC halt bit
//   bit 5   the RTC reset bit (self clearing, the counters go back to zero)
//   bits 0-2 the tilt's rotation register select
// For the gyro, any write to the control byte starts a fresh conversion.
//
// The gyro answers with a 48 bit frame, six bytes of it: six bits of start value, then three
// twelve bit ADC channels for X, Y and Z. A channel rests at 0x6C0 and moves by 52 counts for
// each rad/s the cartridge turns clockwise, clamped to the range of the converter.
//
// The tilt sensor gives two twelve bit axes, 0x3A0 at rest, and a rotation register in degrees
// that the control byte picks between.
//
// The clock's seven registers are packed into the four bytes of the data area, and its day
// counter runs over a four year cycle of 1460 days.

import EmulatorKit

public final class GBAGPIO {
    // MARK: The peripherals a cartridge can carry

    /// The special hardware a cartridge can put behind the GPIO port.
    public enum Peripheral: String, Sendable, Equatable, CaseIterable {
        /// No special hardware: the port is a plain eight bit GPIO.
        case none
        /// The real-time clock.
        case realTimeClock
        /// The twelve bit serial gyro.
        case gyro
        /// The tilt sensor.
        case tilt
        /// The solar sensor.
        case solar
        /// A rumble motor and nothing else.
        case rumble
    }

    // MARK: Register map

    /// The 32 bit GPIO register, at 080000C4h.
    public static let registerAddress: UInt32 = 0x0800_00C4
    /// The data byte.
    public static let dataAddress: UInt32 = 0x0800_00C4
    /// The direction byte.
    public static let directionAddress: UInt32 = 0x0800_00C5
    /// The control byte.
    public static let controlAddress: UInt32 = 0x0800_00C6
    /// The control byte at the address GBATEK gives it.
    public static let controlAliasAddress: UInt32 = 0x0800_00C8

    // MARK: Control byte bits

    /// The rumble motor, on bit 3 of the control byte.
    public static let controlRumble: UInt8 = 0x08
    /// The RTC halt bit, on bit 4 of the control byte.
    public static let controlHalt: UInt8 = 0x10
    /// The RTC reset bit, on bit 5 of the control byte. It clears itself.
    public static let controlReset: UInt8 = 0x20

    // MARK: The gyro

    /// The value the gyro's ADC rests at.
    public static let gyroIdle: UInt16 = 0x6C0
    /// The counts per rad/s the gyro's ADC moves for.
    public static let gyroCountsPerRad: Double = 52
    /// The lowest count the gyro's ADC can report.
    public static let gyroMinimum: UInt16 = 1
    /// The highest count the gyro's ADC can report.
    public static let gyroMaximum: UInt16 = 4094
    /// The six bits the gyro's frame starts with.
    public static let gyroStartValue: UInt8 = 0b101010
    /// The number of bytes in a gyro frame.
    public static let gyroFrameBytes = 6

    // MARK: The tilt sensor

    /// The value the tilt sensor rests at, for both axes.
    public static let tiltIdle: UInt16 = 0x3A0
    /// The counts per m/s² the tilt sensor moves for.
    public static let tiltCountsPerMetre: Double = 78.5
    /// The acceleration of gravity, in m/s².
    public static let gravity: Double = 9.81

    // MARK: The solar sensor

    /// The table the plan gives for the ten light levels.
    ///
    /// The plan says the table comes from other emulators and still wants checking against a
    /// real cartridge, so it is the one thing here that is not measured off hardware.
    public static let solarTable: [UInt8] = [0x00, 0x0E, 0x1C, 0x2A, 0x38,
                                             0x46, 0x54, 0x62, 0x70, 0x7E]

    // MARK: The RTC

    /// The RTC's seven registers, packed into the four bytes of the GPIO data area.
    public struct RTCTime: Sendable, Equatable {
        /// Seconds, 0...59.
        public var seconds: UInt16
        /// Minutes, 0...59.
        public var minutes: UInt16
        /// Hours, 0...23.
        public var hours: UInt16
        /// The day of the month, 1...31.
        public var day: UInt16
        /// The day of the week, 0...6 with 0 as Sunday.
        public var weekday: UInt16
        /// The month, 1...12.
        public var month: UInt16
        /// The year within the four year cycle, 0...3.
        public var year: UInt16
        /// The days since the epoch, 0...1459.
        public var dayCount: UInt16

        public init(seconds: UInt16 = 0, minutes: UInt16 = 0, hours: UInt16 = 0,
                    day: UInt16 = 1, weekday: UInt16 = 0, month: UInt16 = 1,
                    year: UInt16 = 0, dayCount: UInt16 = 0) {
            self.seconds = seconds
            self.minutes = minutes
            self.hours = hours
            self.day = day
            self.weekday = weekday
            self.month = month
            self.year = year
            self.dayCount = dayCount
        }
    }

    /// The number of days in the RTC's four year cycle.
    ///
    /// The cycle is four years of 365 days, so the day counter wraps at 1460 and the year
    /// register goes back to zero with it.
    public static let rtcCycleDays = 1460

    // MARK: State

    /// The peripheral this cartridge carries.
    public let peripheral: Peripheral
    /// Whether the cartridge has a rumble motor.
    public let hasRumbleMotor: Bool

    private var data: UInt8 = 0
    private var direction: UInt8 = 0
    private var control: UInt8 = 0

    // The RTC.
    private var rtcSeconds: UInt16 = 0
    private var rtcMinutes: UInt16 = 0
    private var rtcHours: UInt16 = 0
    private var rtcDay: UInt16 = 1
    private var rtcWeekday: UInt16 = 0
    private var rtcMonth: UInt16 = 1
    private var rtcYear: UInt16 = 0
    private var rtcDayCount: UInt16 = 0
    private var rtcHalted = false
    private var rtcReadIndex = 0
    private var rtcWriteIndex = 0

    // The gyro.
    private var gyroFrame: UInt64 = 0
    private var gyroByteIndex = 0
    private var rotationX = 0.0
    private var rotationY = 0.0

    // The tilt sensor.
    private var gravityX = 0.0
    private var gravityY = 0.0
    private var gravityZ = GBAGPIO.gravity
    private var heading = 0.0
    private var tiltReadIndex = 0

    // The solar sensor.
    private var lightLevel: UInt8 = 0

    // MARK: Making a port

    /// Makes the port for a cartridge with the given game code.
    public init(gameCode: String) {
        self.peripheral = Self.peripheral(forGameCode: gameCode)
        self.hasRumbleMotor = Self.hasMotor(forGameCode: gameCode)
    }

    /// Makes the port for a cartridge whose peripheral is known, which beats the game code.
    public init(gameCode: String, peripheral: Peripheral) {
        self.peripheral = peripheral
        self.hasRumbleMotor = Self.hasMotor(forGameCode: gameCode)
    }

    /// The peripheral a game code implies.
    ///
    /// The codes are the ones the cartridges ship with:
    ///
    ///   "RZW"    WarioWare: Twisted! - the gyro
    ///   a T in the fourth place - the tilt sensor
    ///   "BOK", "BKE", "B3K", "U3I" - the Boktai series, the solar sensor
    ///   "PJE", "R4E" - the P-Letter series and Rockman EXE 4.5, the clock
    ///   "MOR"    Drill Dozer - the rumble motor
    public static func peripheral(forGameCode code: String) -> Peripheral {
        let upper = code.uppercased()
        if upper.hasPrefix("RZW") { return .gyro }
        if upper.count == 4, upper.hasSuffix("T") { return .tilt }
        if solarCodes.contains(where: { upper.hasPrefix($0) }) { return .solar }
        if clockCodes.contains(where: { upper.hasPrefix($0) }) { return .realTimeClock }
        if motorCodes.contains(where: { upper.hasPrefix($0) }) { return .rumble }
        return .none
    }

    /// Whether a game code names a cartridge with a rumble motor.
    public static func hasMotor(forGameCode code: String) -> Bool {
        let upper = code.uppercased()
        return motorCodes.contains(where: { upper.hasPrefix($0) })
            || upper.hasPrefix("RZW")
    }

    private static let solarCodes = ["BOK", "BKE", "B3K", "U3I"]
    private static let clockCodes = ["PJE", "R4E"]
    private static let motorCodes = ["MOR"]

    // MARK: The port

    /// The data byte, the byte the port presents to the guest.
    public var dataByte: UInt8 { data }
    /// The direction byte: a set bit is an output.
    public var directionByte: UInt8 { direction }
    /// The control byte.
    public var controlByte: UInt8 { control }
    /// Whether the rumble motor is running.
    public var rumbleActive: Bool { control & Self.controlRumble != 0 }

    /// Reads the 32 bit GPIO register.
    ///
    /// The read gives the data byte and the direction byte, and the control byte above them.
    public func read32(_ address: UInt32) -> UInt32 {
        guard address >= Self.registerAddress, address <= Self.registerAddress &+ 3 else { return 0 }
        switch address &- Self.registerAddress {
        case 0:
            return UInt32(readDataByte()) | UInt32(direction) << 8 | UInt32(control) << 16
        case 1:
            return UInt32(direction) | UInt32(control) << 8
        case 2:
            return UInt32(control)
        default:
            return 0
        }
    }

    /// Writes the 32 bit GPIO register.
    public func write32(_ address: UInt32, _ value: UInt32) {
        guard address >= Self.registerAddress, address <= Self.registerAddress &+ 3 else { return }
        switch address &- Self.registerAddress {
        case 0:
            writeDataByte(UInt8(value & 0xFF))
            direction = UInt8((value >> 8) & 0xFF)
            writeControl(UInt8((value >> 16) & 0xFF))
        case 1:
            direction = UInt8(value & 0xFF)
            writeControl(UInt8((value >> 8) & 0xFF))
        case 2:
            writeControl(UInt8(value & 0xFF))
        default:
            break
        }
    }

    /// Reads a byte of the port.
    public func read8(_ address: UInt32) -> UInt8 {
        guard address >= Self.registerAddress, address <= Self.controlAliasAddress else { return 0 }
        switch address {
        case Self.dataAddress:
            return readDataByte()
        case Self.directionAddress:
            return direction
        case Self.controlAddress, Self.controlAliasAddress:
            return control
        default:
            return 0
        }
    }

    /// Writes a byte of the port.
    public func write8(_ address: UInt32, _ value: UInt8) {
        guard address >= Self.registerAddress, address <= Self.controlAliasAddress else { return }
        switch address {
        case Self.dataAddress:
            writeDataByte(value)
        case Self.directionAddress:
            direction = value
        case Self.controlAddress, Self.controlAliasAddress:
            writeControl(value)
        default:
            break
        }
    }

    /// Reads the data byte and moves a serial peripheral on to its next byte.
    private func readDataByte() -> UInt8 {
        switch peripheral {
        case .gyro:
            let byte = UInt8((gyroFrame >> UInt64(56 - 8 * gyroByteIndex)) & 0xFF)
            gyroByteIndex = (gyroByteIndex + 1) % Self.gyroFrameBytes
            return byte
        case .realTimeClock:
            let word = Self.packRTC(currentTime())
            let byte = UInt8((word >> UInt32(8 * rtcReadIndex)) & 0xFF)
            rtcReadIndex = (rtcReadIndex + 1) & 3
            return byte
        case .tilt:
            let word = tiltWord()
            let byte = UInt8((word >> UInt32(8 * tiltReadIndex)) & 0xFF)
            tiltReadIndex = (tiltReadIndex + 1) & 3
            return byte
        case .solar:
            return lightLevel
        case .none, .rumble:
            // A plain port: a bit set in the direction byte is an output, so the guest reads
            // back what it wrote. A bit clear is an input, and nothing drives them.
            return data & direction
        }
    }

    /// Writes the data byte.
    private func writeDataByte(_ value: UInt8) {
        switch peripheral {
        case .gyro:
            // The guest shifts the start value in to start a conversion.
            if value >> 2 == Self.gyroStartValue { armGyro() }
        case .realTimeClock:
            var word = Self.packRTC(currentTime())
            let shift = UInt32(8 * rtcWriteIndex)
            word = (word & ~(0xFF << shift)) | (UInt32(value) << shift)
            applyRTC(word)
            rtcWriteIndex = (rtcWriteIndex + 1) & 3
        case .tilt, .solar, .none, .rumble:
            data = value
        }
    }

    /// Writes the control byte.
    public func writeControl(_ value: UInt8) {
        control = value & ~Self.controlReset
        if peripheral == .realTimeClock {
            rtcHalted = value & Self.controlHalt != 0
            if value & Self.controlReset != 0 { resetRTC() }
        }
        if peripheral == .gyro { armGyro() }
    }

    // MARK: The RTC

    /// The clock's current reading.
    public var rtcTime: RTCTime { currentTime() }

    /// Whether the clock is halted.
    public var rtcIsHalted: Bool { rtcHalted }

    /// Runs the clock on by the given number of seconds.
    ///
    /// A halted clock does not move.
    public func advance(seconds: Double) {
        guard peripheral == .realTimeClock, !rtcHalted else { return }
        let whole = Int(seconds.rounded())
        let total = Int(rtcHours) * 3600 + Int(rtcMinutes) * 60 + Int(rtcSeconds) + whole
        let days = total / 86_400
        let timeOfDay = total % 86_400
        rtcHours = UInt16(timeOfDay / 3600)
        rtcMinutes = UInt16((timeOfDay % 3600) / 60)
        rtcSeconds = UInt16(timeOfDay % 60)
        guard days != 0 else { return }
        rtcDayCount = UInt16((Int(rtcDayCount) + days) % Self.rtcCycleDays)
        rtcWeekday = UInt16((Int(rtcWeekday) + days) % 7)
        applyDayCount()
    }

    /// Puts the clock's counters back to zero.
    public func resetRTC() {
        rtcSeconds = 0
        rtcMinutes = 0
        rtcHours = 0
        rtcDay = 1
        rtcWeekday = 0
        rtcMonth = 1
        rtcYear = 0
        rtcDayCount = 0
    }

    /// Packs the clock's registers into the four bytes of the GPIO data area.
    ///
    ///   bits  0-5   seconds
    ///   bits  6-11  minutes
    ///   bits 12-16  hours
    ///   bits 17-21  day of the month
    ///   bits 22-24  day of the week
    ///   bits 25-28  month
    ///   bits 29-30  year within the four year cycle
    public static func packRTC(_ time: RTCTime) -> UInt32 {
        var word: UInt32 = 0
        word |= UInt32(time.seconds & 0x3F)
        word |= UInt32(time.minutes & 0x3F) << 6
        word |= UInt32(time.hours & 0x1F) << 12
        word |= UInt32(time.day & 0x1F) << 17
        word |= UInt32(time.weekday & 0x07) << 22
        word |= UInt32(time.month & 0x0F) << 25
        word |= UInt32(time.year & 0x03) << 29
        return word
    }

    /// Unpacks the clock's registers from the four bytes of the GPIO data area.
    public static func unpackRTC(_ word: UInt32) -> RTCTime {
        RTCTime(seconds: UInt16(word & 0x3F),
                minutes: UInt16((word >> 6) & 0x3F),
                hours: UInt16((word >> 12) & 0x1F),
                day: UInt16((word >> 17) & 0x1F),
                weekday: UInt16((word >> 22) & 0x07),
                month: UInt16((word >> 25) & 0x0F),
                year: UInt16((word >> 29) & 0x03),
                dayCount: 0)
    }

    private func currentTime() -> RTCTime {
        RTCTime(seconds: rtcSeconds, minutes: rtcMinutes, hours: rtcHours,
                day: rtcDay, weekday: rtcWeekday, month: rtcMonth, year: rtcYear,
                dayCount: rtcDayCount)
    }

    private func applyRTC(_ word: UInt32) {
        let time = Self.unpackRTC(word)
        rtcSeconds = time.seconds
        rtcMinutes = time.minutes
        rtcHours = time.hours
        rtcDay = time.day
        rtcWeekday = time.weekday
        rtcMonth = time.month
        rtcYear = time.year
        rtcDayCount = Self.dayCount(year: time.year, month: time.month, day: time.day)
    }

    private func applyDayCount() {
        let year = UInt16(Int(rtcDayCount) / 365)
        var rest = Int(rtcDayCount) % 365
        var month = UInt16(1)
        for length in Self.monthLengths {
            if rest < length { break }
            rest -= length
            month += 1
        }
        rtcYear = year
        rtcMonth = month
        rtcDay = UInt16(rest + 1)
    }

    /// The days since the epoch for a date within the four year cycle.
    private static func dayCount(year: UInt16, month: UInt16, day: UInt16) -> UInt16 {
        let monthIndex = min(max(Int(month), 1), 12) - 1
        var rest = Int(year) * 365
        for i in 0..<monthIndex { rest += Int(monthLengths[i]) }
        rest += max(Int(day) - 1, 0)
        return UInt16(rest % rtcCycleDays)
    }

    /// The length of each month, in days. The cycle has no leap year.
    private static let monthLengths: [Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    // MARK: The gyro

    /// Sets the cartridge's angular rate, in radians per second, clockwise positive.
    public func setRotation(x: Double = 0, y: Double = 0) {
        rotationX = x
        rotationY = y
    }

    /// The gyro's frame: the start value and the three ADC channels.
    public func gyroFrameValues() -> (start: UInt8, x: UInt16, y: UInt16, z: UInt16) {
        (Self.gyroStartValue, gyroCounts(forRate: rotationX), gyroCounts(forRate: rotationY),
         gyroCounts(forRate: 0))
    }

    /// The count the gyro's ADC gives for a rotation rate.
    public func gyroCounts(forRate rate: Double) -> UInt16 {
        let counts = Double(Self.gyroIdle) + Self.gyroCountsPerRad * rate
        return UInt16(min(max(counts.rounded(), Double(Self.gyroMinimum)), Double(Self.gyroMaximum)))
    }

    /// Starts a fresh conversion, which fills the frame with the current rate.
    private func armGyro() {
        let x = gyroCounts(forRate: rotationX)
        let y = gyroCounts(forRate: rotationY)
        let z = gyroCounts(forRate: 0)
        var frame: UInt64 = UInt64(Self.gyroStartValue & 0x3F) << 58
        frame |= UInt64(x & 0x0FFF) << 46
        frame |= UInt64(y & 0x0FFF) << 34
        frame |= UInt64(z & 0x0FFF) << 22
        gyroFrame = frame
        gyroByteIndex = 0
    }

    // MARK: The tilt sensor

    /// Sets the gravity the tilt sensor is feeling, in m/s².
    public func setGravity(x: Double = 0, y: Double = 0, z: Double = GBAGPIO.gravity) {
        gravityX = x
        gravityY = y
        gravityZ = z
    }

    /// Sets the heading the tilt sensor is facing, in degrees.
    public func setHeading(_ degrees: Double) {
        heading = degrees
    }

    /// The tilt sensor's reading: the two axes and the selected rotation register.
    public func tiltValues() -> (x: UInt16, y: UInt16, rotation: UInt8) {
        (tiltX(), tiltY(), tiltRotation())
    }

    /// The tilt sensor's four bytes, the same bytes the data byte shifts out.
    public func tiltWord() -> UInt32 {
        var word: UInt32 = 0
        word |= UInt32(tiltX() & 0x0FFF)
        word |= UInt32(tiltY() & 0x0FFF) << 12
        word |= UInt32(tiltRotation()) << 24
        return word
    }

    private func tiltX() -> UInt16 {
        let counts = Double(Self.tiltIdle) - (Self.tiltCountsPerMetre * gravityX).rounded()
        return UInt16(min(max(counts, 0), 4095))
    }

    private func tiltY() -> UInt16 {
        let counts = Double(Self.tiltIdle) + (Self.tiltCountsPerMetre * gravityY).rounded()
        return UInt16(min(max(counts, 0), 4095))
    }

    private func tiltRotation() -> UInt8 {
        let pitch = (Self.atan2(-gravityY, gravityZ) * 180 / .pi).rounded()
        let roll = (Self.atan2(gravityX, gravityZ) * 180 / .pi).rounded()
        let angle: Double
        switch control & 0x07 {
        case 1: angle = roll
        case 2: angle = heading
        default: angle = pitch
        }
        var wrapped = Int(angle) % 256
        if wrapped < 0 { wrapped += 256 }
        return UInt8(wrapped)
    }

    /// The angle of the point (x, y), in radians.
    ///
    /// The tilt sensor needs the angle of a vector in the plane. The module stays free of
    /// Foundation so that it still builds on Linux, so the function is written out here rather
    /// than imported.
    private static func atan2(_ y: Double, _ x: Double) -> Double {
        if x == 0 && y == 0 { return 0 }
        let ax = abs(x), ay = abs(y)
        // The series in t only converges quickly near the origin, so the smaller of the two is
        // divided by the larger, and a ratio past a half is turned into one of at most a third
        // with atan(t) = 45° + atan((t - 1) / (t + 1)).
        var t = min(ax, ay) / max(ax, ay)
        var offset = 0.0
        if t > 0.5 {
            offset = .pi / 4
            t = (t - 1) / (t + 1)
        }
        let series = t * (1 - t * t * (1.0 / 3 - t * t * (1.0 / 5 - t * t / 7)))
        let small = series + offset
        let angle = ax >= ay ? small : .pi / 2 - small
        switch (x, y) {
        case (_, 0):
            return x >= 0 ? 0 : .pi
        case (0, _):
            return y > 0 ? .pi / 2 : -.pi / 2
        case (let x, let y) where x > 0 && y > 0:
            return angle
        case (let x, let y) where x < 0 && y > 0:
            return .pi - angle
        case (let x, let y) where x < 0 && y < 0:
            return -(.pi - angle)
        default:
            return -angle
        }
    }

    // MARK: The solar sensor

    /// Sets the light level the solar sensor sees, 0...255.
    public func setLightLevel(_ level: Int) {
        lightLevel = UInt8(min(max(level, 0), 255))
    }

    /// Sets the light level from the plan's ten step scale.
    public func setLightIntensity(_ level: Int) {
        guard level > 0, level <= Self.solarTable.count else { return }
        let v = 0x16 + Int(Self.solarTable[level - 1])
        setLightLevel(0xFF - v)
    }
}
