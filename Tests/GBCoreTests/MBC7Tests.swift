import Testing
@testable import GBCore

@Suite struct MBC7Tests {

    /// Drives the latch sequence, which is the only way the registers update.
    private func latched(gravity: SIMD3<Float> = .zero, gain: Float = 1) -> MBC7Accelerometer {
        var mapper = MBC7Accelerometer(gravity: gravity, gain: gain)
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        return mapper
    }

    // MARK: Value

    @Test func centreValueIs81D0WithNoTilt() {
        let mapper = latched()
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0)
        // The centre falls out of the formula rather than being a constant, so a tilt moves it.
        let tilted = latched(gravity: SIMD3(0.1, 0, 0))
        #expect(tilted.read(MBC7Accelerometer.xAddress) != 0x81D0)
    }

    @Test func positiveXTiltLowersTheXRegister() {
        // 0.5 g on X is 56 counts at unity gain, and X runs the opposite way to Y.
        let mapper = latched(gravity: SIMD3(0.5, 0, 0))
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
    }

    @Test func positiveYTiltRaisesTheYRegister() {
        let mapper = latched(gravity: SIMD3(0, 0.5, 0))
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0 + 56)
    }

    @Test func negativeTiltMovesTheRegistersTheOtherWay() {
        let mapper = latched(gravity: SIMD3(-0.5, -0.5, 0))
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 + 56)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0 - 56)
    }

    @Test func theXAndYSignsAreOpposite() {
        let mapper = latched(gravity: SIMD3(0.5, 0.5, 0))
        let x = Int(mapper.read(MBC7Accelerometer.xAddress))
        let y = Int(mapper.read(MBC7Accelerometer.yAddress))
        #expect(x < 0x81D0)
        #expect(y > 0x81D0)
        #expect(0x81D0 - x == y - 0x81D0)
    }

    @Test func anAxisOnlyTiltLeavesTheOtherAxisAtTheCentre() {
        let mapper = latched(gravity: SIMD3(0.5, 0, 0))
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0)
        let other = latched(gravity: SIMD3(0, 0.5, 0))
        #expect(other.read(MBC7Accelerometer.xAddress) == 0x81D0)
    }

    @Test func theRoundingIsToTheNearest() {
        // 112 * 0.004 = 0.448, which rounds down to 0.
        let down = latched(gravity: SIMD3(0.004, 0, 0))
        #expect(down.read(MBC7Accelerometer.xAddress) == 0x81D0)
        // 112 * 0.006 = 0.672, which rounds up to 1.
        let up = latched(gravity: SIMD3(0.006, 0, 0))
        #expect(up.read(MBC7Accelerometer.xAddress) == 0x81D0 - 1)
        // Exactly half a count rounds away from zero.
        let half = latched(gravity: SIMD3(0.5 / 112, 0, 0))
        #expect(half.read(MBC7Accelerometer.xAddress) == 0x81D0 - 1)
    }

    // MARK: Gain

    @Test func theGainScalesTheResult() {
        // 0.5 g at gain 1.5 is 84 counts.
        let mapper = latched(gravity: SIMD3(0.5, 0, 0), gain: 1.5)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 84)
    }

    @Test func theGainDefaultsToUnity() {
        #expect(MBC7Accelerometer().gain == 1)
        #expect(latched(gravity: SIMD3(0.5, 0, 0)).read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
    }

    @Test func theGainIsClampedToItsRange() {
        var low = MBC7Accelerometer(gain: 0.1)
        var high = MBC7Accelerometer(gain: 9)
        #expect(low.gain == 1)
        #expect(high.gain == 1.5)
        low.setGain(0.5)
        high.setGain(3)
        #expect(low.gain == 1)
        #expect(high.gain == 1.5)
    }

    @Test func aNonFiniteGainFallsBackToUnity() {
        var mapper = MBC7Accelerometer()
        mapper.setGain(Float.nan)
        #expect(mapper.gain == 1)
        mapper.setGain(Float.infinity)
        #expect(mapper.gain == 1.5)
    }

    // MARK: Latch

    @Test func theLatchSequenceIsRequiredBeforeValuesAreReadable() {
        var mapper = MBC7Accelerometer(gravity: SIMD3(0.5, 0.5, 0))
        // No latch at all: the registers still hold the centre.
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0)
        // Half a sequence is not enough either.
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0 + 56)
    }

    @Test func aWrongLatchSequenceLeavesTheRegistersAtTheirLastValue() {
        var mapper = latched(gravity: SIMD3(0.5, 0, 0))
        let lastX = mapper.read(MBC7Accelerometer.xAddress)
        // A new tilt, but the latch is never completed, so the registers keep the old value.
        mapper.setGravity(SIMD3(0, 0.5, 0))
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == lastX)
        // 0xAA without the preceding 0x55 does not latch either.
        var fresh = MBC7Accelerometer(gravity: SIMD3(0.5, 0, 0))
        fresh.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(fresh.read(MBC7Accelerometer.xAddress) == 0x81D0)
        // A stray write in between resets the sequence, so the following 0xAA does nothing.
        var interrupted = MBC7Accelerometer(gravity: SIMD3(0.5, 0, 0))
        interrupted.write(MBC7Accelerometer.latchAddress, 0x55)
        interrupted.write(MBC7Accelerometer.latchAddress, 0x12)
        interrupted.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(interrupted.read(MBC7Accelerometer.xAddress) == 0x81D0)
    }

    @Test func repeatingTheFirstByteStillLatches() {
        var mapper = MBC7Accelerometer(gravity: SIMD3(0.5, 0, 0))
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
    }

    @Test func theLatchStatusRegisterReportsTheSequence() {
        var mapper = MBC7Accelerometer()
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0x00)
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0xAA)
        // A stray byte clears the state again.
        mapper.write(MBC7Accelerometer.latchAddress, 0x00)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0x00)
    }

    @Test func twoLatchesInARowBothTakeASample() {
        var mapper = MBC7Accelerometer(gravity: SIMD3(0.5, 0, 0))
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
        mapper.setGravity(SIMD3(0, 0.5, 0))
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0 + 56)
    }

    @Test func gravityOnlyReachesTheRegistersOnTheNextLatch() {
        var mapper = MBC7Accelerometer()
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        mapper.setGravity(SIMD3(0.5, 0, 0))
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
    }

    // MARK: Range

    @Test func theSensorSaturatesAtItsFullScaleRange() {
        // The ADXL202E in the cartridge is a 2 g part, so a bigger acceleration pins the output
        // at the limit rather than following the input.
        let atLimit = latched(gravity: SIMD3(2, 0, 0))
        #expect(atLimit.read(MBC7Accelerometer.xAddress) == 0x81D0 - 224)
        let beyond = latched(gravity: SIMD3(50, 0, 0))
        #expect(beyond.read(MBC7Accelerometer.xAddress) == 0x81D0 - 224)
        let negative = latched(gravity: SIMD3(-50, 0, 0))
        #expect(negative.read(MBC7Accelerometer.xAddress) == 0x81D0 + 224)
    }

    @Test func theRegisterNeverRunsPastTheSensorRange() {
        // Clamping at 0x0000 and 0xFFFF would report an impossible reading for a tilt the
        // sensor cannot even see.
        let mapper = latched(gravity: SIMD3(1000, 1000, 0))
        let x = mapper.read(MBC7Accelerometer.xAddress)
        let y = mapper.read(MBC7Accelerometer.yAddress)
        #expect(x != 0)
        #expect(y != 0xFFFF)
        #expect(x == 0x81D0 - 224)
        #expect(y == 0x81D0 + 224)
    }

    @Test func aNonFiniteGravityDoesNotBreakTheRegisters() {
        var mapper = MBC7Accelerometer()
        mapper.setGravity(SIMD3(Float.nan, Float.infinity, 0))
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        // The unreadable axis counts as flat, the runaway one saturates.
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0 + 224)
    }

    // MARK: Tilt

    @Test func theTiltRegisterHoldsThePlanarMagnitude() {
        // A 45 degree tilt of 1 g is 0.7071 g in each axis, so the magnitude is 1 g: 112 counts.
        let mapper = latched(gravity: SIMD3(0.70710678, 0.70710678, 0))
        #expect(mapper.read(MBC7Accelerometer.tiltAddress) == 112)
    }

    @Test func theTiltRegisterIgnoresTheAxisSigns() {
        // 0.3 and 0.4 make a 0.5 g hypotenuse, whichever way round the axes are.
        let upright = latched(gravity: SIMD3(0.3, 0.4, 0))
        let flipped = latched(gravity: SIMD3(0.4, 0.3, 0))
        #expect(upright.read(MBC7Accelerometer.tiltAddress) == 56)
        #expect(flipped.read(MBC7Accelerometer.tiltAddress) == 56)
    }

    @Test func theRotationSensorRegisterIsNotImplemented() {
        let mapper = latched(gravity: SIMD3(0.5, 0.5, 0))
        // The other registers answer for the same tilt, so the zero here is specific to the
        // rotation sensor rather than a register file that reads nothing.
        #expect(mapper.read(MBC7Accelerometer.xAddress) != 0)
        #expect(mapper.read(MBC7Accelerometer.tiltAddress) != 0)
        #expect(mapper.read(MBC7Accelerometer.rotationAddress) == 0)
    }

    // MARK: Address decoding

    @Test func theRegistersAreLittleEndian() {
        let mapper = latched(gravity: SIMD3(0.5, 0, 0))
        let value = mapper.read(MBC7Accelerometer.xAddress)
        #expect(mapper.readByte(MBC7Accelerometer.xAddress) == UInt8(truncatingIfNeeded: value))
        #expect(mapper.readByte(MBC7Accelerometer.xAddress + 1) == UInt8(truncatingIfNeeded: value >> 8))
    }

    @Test func theLowAddressBitsDoNotChangeTheRegister() {
        // The sensor takes bits 4-7 of the address, so the low nibble is ignored.
        let mapper = latched(gravity: SIMD3(0.5, 0.5, 0))
        #expect(mapper.read(MBC7Accelerometer.xAddress + 4) == mapper.read(MBC7Accelerometer.xAddress))
        #expect(mapper.read(MBC7Accelerometer.yAddress + 3) == mapper.read(MBC7Accelerometer.yAddress))
        #expect(mapper.read(MBC7Accelerometer.tiltAddress + 5) == mapper.read(MBC7Accelerometer.tiltAddress))
    }

    @Test func theOtherAddressesReadZero() {
        let mapper = latched(gravity: SIMD3(0.5, 0.5, 0))
        // The latch register is write-only, and the rest of the file selects no register.
        for address: UInt16 in [0xA000, 0xA040, 0xA050, 0xA070, 0xA090, 0xA0F0] {
            #expect(mapper.read(address) == 0)
        }
    }

    @Test func writesOutsideTheLatchRegisterAreIgnored() {
        var mapper = MBC7Accelerometer(gravity: SIMD3(0.5, 0, 0))
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        // A write to the status register must not latch, so the latched value stays put.
        mapper.write(MBC7Accelerometer.latchStatusAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0xAA)
        // A write to the X register is not a latch byte either.
        mapper.write(MBC7Accelerometer.xAddress, 0x55)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 56)
    }
}
