/// The MBC7 accelerometer mapper, used by Kirby Tilt 'n' Tumble and Command Master.
///
/// A struct with an explicit mutating API rather than a class: the mapper owns no shared mutable
/// state of its own and the emulator core that will hold it is the only writer, so a value type
/// keeps the cartridge read path free of locks.
///
/// The mapper covers the accelerometer (X and Y) and the tilt magnitude. The 3D rotation sensor
/// register at 0xA080 is not implemented and reads zero: it needs the angular rate rather than the
/// gravity vector, and no game in scope depends on it.
public struct MBC7Accelerometer: Sendable, Equatable {

    // MARK: Constants

    /// Register value with the device level.
    public static let centre: UInt16 = 0x81D0
    /// Counts per g at unity gain.
    public static let countsPerG: Float = 112
    /// Gain range the cartridge supports.
    public static let minimumGain: Float = 1
    public static let maximumGain: Float = 1.5

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

    // MARK: State

    /// Gravity in units of g, in the device frame, relative to the neutral pose.
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

    /// Sets the gravity vector in units of g, relative to the neutral pose. The latched registers
    /// only move on the next latch, so a game never sees a half-updated pair.
    public mutating func setGravity(_ value: SIMD3<Float>) {
        gravity = value
    }

    /// Sets the sensor gain. Values outside 1...1.5 are clamped to that range.
    public mutating func setGain(_ value: Float) {
        gain = MBC7Accelerometer.clampGain(value)
    }

    // MARK: Registers

    /// Handles a write into the cartridge RAM window. Only 0xA000 takes the latch sequence.
    public mutating func write(_ address: UInt16, _ value: UInt8) {
        guard address == MBC7Accelerometer.latchAddress else { return }
        latchStep(value)
    }

    /// Reads a register as a 16-bit value. The registers are little-endian, so the low byte sits
    /// at the register address and the high byte one address above it.
    public func read(_ address: UInt16) -> UInt16 {
        switch address & 0xFFFE {
        case MBC7Accelerometer.latchStatusAddress: return UInt16(latchState.rawValue)
        case MBC7Accelerometer.xAddress: return latchedX
        case MBC7Accelerometer.yAddress: return latchedY
        case MBC7Accelerometer.tiltAddress: return latchedTilt
        default: return 0
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
        let centre = Int(MBC7Accelerometer.centre)
        latchedX = MBC7Accelerometer.clampToRegister(centre - counts(gravity.x))
        latchedY = MBC7Accelerometer.clampToRegister(centre + counts(gravity.y))
        let planar = (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot()
        latchedTilt = MBC7Accelerometer.clampToRegister(counts(planar))
    }

    // MARK: Tilt maths

    /// Counts for a gravity component: 112 per g, scaled by the gain, rounded to nearest.
    private func counts(_ component: Float) -> Int {
        let scaled = MBC7Accelerometer.countsPerG * gain * component
        guard !scaled.isNaN else { return 0 }
        if scaled >= 65_536 { return 65_536 }
        if scaled <= -65_536 { return -65_536 }
        return Int(scaled.rounded())
    }

    private static func clampGain(_ value: Float) -> Float {
        min(max(value, minimumGain), maximumGain)
    }

    /// Clamps a value offset from the centre into the 16-bit register range.
    private static func clampToRegister(_ value: Int) -> UInt16 {
        if value < 0 { return 0 }
        if value > 0xFFFF { return 0xFFFF }
        return UInt16(value)
    }
}
