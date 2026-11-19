/// The MBC7 accelerometer mapper, used by Kirby Tilt 'n' Tumble and Command Master.
///
/// A struct with an explicit mutating API rather than a class: the mapper owns no shared mutable
/// state of its own and the emulator core that will hold it is the only writer, so a value type
/// keeps the cartridge read path free of locks.
///
/// The mapper covers the accelerometer (X and Y) and the tilt magnitude. The 3D rotation sensor
/// register at 0xA080 is not implemented and reads zero: it needs the angular rate rather than the
/// gravity vector, and no game in scope depends on it.
///
/// The register map follows the project's own MBC7 notes, which read X and Y as 16-bit values at
/// 0xA020 and 0xA030 and put the tilt and rotation registers at 0xA060 and 0xA080. The Pan Docs
/// map differs: it splits X and Y into separate low and high byte registers, takes the latch
/// sequence on 0xA000 and 0xA010 rather than on 0xA000 alone, leaves the accelerometer at $8000
/// until the first latch rather than at the centre, and puts the serial EEPROM at 0xA080. This
/// mapper follows the project notes, whose centre value and signs were confirmed against
/// Kirby's calibration screen.
public struct MBC7Accelerometer: Sendable, Equatable {

    // MARK: Constants

    /// Register value with the device level.
    public static let centre: UInt16 = 0x81D0
    /// Counts per g at unity gain.
    public static let countsPerG: Float = 112
    /// Gain range the cartridge supports.
    public static let minimumGain: Float = 1
    public static let maximumGain: Float = 1.5
    /// Full-scale range of the ADXL202E in the cartridge, in g. The sensor output pins here, so a
    /// reading past it stops moving rather than following the acceleration.
    public static let fullScale: Float = 2

    /// Register that takes the latch sequence.
    public static let latchAddress: UInt16 = 0xA000
    /// Register that reports the latch state.
    public static let latchStatusAddress: UInt16 = 0xA010
    /// Register holding the latched X value.
    public static let xAddress: UInt16 = 0xA020
    /// Register holding the latched Y value.
    public static let yAddress: UInt16 = 0xA030
    /// Register holding the latched tilt.
    public static let tiltAddress: UInt16 = 0xA060
    /// Register holding the 3D rotation sensor reading, which this mapper does not implement.
    public static let rotationAddress: UInt16 = 0xA080

    // MARK: Registers

    /// One of the mapper's registers, or nothing for an address that selects none.
    private enum Register {
        case latch
        case status
        case x
        case y
        case tilt
        case rotation
    }

    /// Picks the register an address selects. The sensor's registers live in the 0xA000-0xAFFF
    /// window and are chosen by bits 4-7 of the address; the low nibble and bits 8-11 are
    /// ignored, so 0xA020 and 0xA12F select the same register.
    private static func register(at address: UInt16) -> Register? {
        guard address & 0xF000 == 0xA000 else { return nil }
        switch address & 0x00F0 {
        case 0x00: return .latch
        case 0x10: return .status
        case 0x20: return .x
        case 0x30: return .y
        case 0x60: return .tilt
        case 0x80: return .rotation
        default: return nil
        }
    }

    // MARK: State

    /// Gravity in the device frame, in units of g. Only the two axes the sensor measures are
    /// used; the cartridge accelerometer has no third axis.
    public private(set) var gravity: SIMD3<Float>
    /// Sensor gain, clamped to 1...1.5.
    public private(set) var gain: Float
    /// Latched accelerometer X value.
    public private(set) var latchedX: UInt16 = MBC7Accelerometer.centre
    /// Latched accelerometer Y value.
    public private(set) var latchedY: UInt16 = MBC7Accelerometer.centre
    /// Latched tilt magnitude, in the same counts as X and Y.
    public private(set) var latchedTilt: UInt16 = 0
    private var latchState: Latch = .idle

    /// Latch state, mirrored in the 0xA010 register.
    private enum Latch: UInt8 {
        case idle = 0x00
        case first = 0x55
        case second = 0xAA
    }

    public init(gravity: SIMD3<Float> = .zero, gain: Float = MBC7Accelerometer.minimumGain) {
        self.gravity = gravity
        self.gain = MBC7Accelerometer.clampGain(gain)
    }

    // MARK: Input

    /// Sets the gravity vector in units of g, in the device frame. The latched registers only move
    /// on the next latch, so a game never sees a half-updated pair.
    public mutating func setGravity(_ value: SIMD3<Float>) {
        gravity = value
    }

    /// Sets the sensor gain. Values outside 1...1.5 are clamped to that range.
    public mutating func setGain(_ value: Float) {
        gain = MBC7Accelerometer.clampGain(value)
    }

    // MARK: Register access

    /// Handles a write into the cartridge RAM window. Only the latch register takes a write.
    public mutating func write(_ address: UInt16, _ value: UInt8) {
        guard MBC7Accelerometer.register(at: address) == .latch else { return }
        latchStep(value)
    }

    /// Reads a register as a 16-bit value. The registers are little-endian, so the low byte sits
    /// at the register address and the high byte one address above it.
    public func read(_ address: UInt16) -> UInt16 {
        guard let register = MBC7Accelerometer.register(at: address) else { return 0 }
        switch register {
        case .status: return UInt16(latchState.rawValue)
        case .x: return latchedX
        case .y: return latchedY
        case .tilt: return latchedTilt
        // The rotation sensor needs the angular rate rather than the gravity vector.
        case .rotation: return 0
        case .latch: return 0
        }
    }

    /// Reads one byte of the register file.
    public func readByte(_ address: UInt16) -> UInt8 {
        let value = read(address)
        return address & 1 == 0 ? UInt8(truncatingIfNeeded: value) : UInt8(truncatingIfNeeded: value >> 8)
    }

    // MARK: Latch

    /// Advances the latch state machine. The sequence is 0x55 then 0xAA; anything else drops the
    /// machine back to idle and leaves the registers alone.
    private mutating func latchStep(_ value: UInt8) {
        switch value {
        case 0x55:
            latchState = .first
        case 0xAA:
            guard latchState == .first else {
                latchState = .idle
                return
            }
            sample()
            latchState = .second
        default:
            latchState = .idle
        }
    }

    /// Takes the current gravity reading into the latched registers.
    private mutating func sample() {
        let x = MBC7Accelerometer.saturated(gravity.x)
        let y = MBC7Accelerometer.saturated(gravity.y)
        let centre = Int(MBC7Accelerometer.centre)
        latchedX = MBC7Accelerometer.clampToRegister(centre - counts(x))
        latchedY = MBC7Accelerometer.clampToRegister(centre + counts(y))
        // The tilt register carries the magnitude of the in-plane component, the part of the tilt
        // the two measured axes can see.
        latchedTilt = MBC7Accelerometer.clampToRegister(counts((x * x + y * y).squareRoot()))
    }

    // MARK: Tilt maths

    /// Counts for a gravity component: 112 per g, scaled by the gain, rounded to nearest. The
    /// component is already within the sensor's range, so the product cannot overflow.
    private func counts(_ component: Float) -> Int {
        let scaled = MBC7Accelerometer.countsPerG * gain * component
        return Int(scaled.rounded())
    }

    /// Clamps a component to the sensor's full-scale range. Past it the sensor output pins, so an
    /// overloaded axis reads as full scale. A reading that is not a number at all reads as flat.
    private static func saturated(_ component: Float) -> Float {
        guard !component.isNaN else { return 0 }
        return min(max(component, -fullScale), fullScale)
    }

    private static func clampGain(_ value: Float) -> Float {
        guard !value.isNaN else { return minimumGain }
        return min(max(value, minimumGain), maximumGain)
    }

    /// Clamps a value offset from the centre into the 16-bit register range. The sensor saturates
    /// well inside this range, so it is a backstop rather than the limit the player sees.
    private static func clampToRegister(_ value: Int) -> UInt16 {
        if value < 0 { return 0 }
        if value > 0xFFFF { return 0xFFFF }
        return UInt16(value)
    }
}
