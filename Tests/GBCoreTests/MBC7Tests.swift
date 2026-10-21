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

    @Test func centreValueIs81D0WithNoTilt() {
        let mapper = latched()
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        #expect(mapper.read(MBC7Accelerometer.yAddress) == 0x81D0)
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

    @Test func theGainScalesTheResult() {
        // 0.5 g at gain 1.5 is 84 counts.
        let mapper = latched(gravity: SIMD3(0.5, 0, 0), gain: 1.5)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0 - 84)
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

    @Test func theXAndYSignsAreOpposite() {
        let mapper = latched(gravity: SIMD3(0.5, 0.5, 0))
        let x = Int(mapper.read(MBC7Accelerometer.xAddress))
        let y = Int(mapper.read(MBC7Accelerometer.yAddress))
        #expect(x < 0x81D0)
        #expect(y > 0x81D0)
        #expect(0x81D0 - x == y - 0x81D0)
    }

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

    @Test func theLatchStatusRegisterReportsTheSequence() {
        var mapper = MBC7Accelerometer()
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0x00)
        mapper.write(MBC7Accelerometer.latchAddress, 0x55)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0x55)
        mapper.write(MBC7Accelerometer.latchAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0xAA)
    }

    @Test func theValueSaturatesAtTheEndsOfTheRange() {
        // A huge tilt would take X below zero and Y past 0xFFFF.
        let huge = latched(gravity: SIMD3(1000, 1000, 0))
        #expect(huge.read(MBC7Accelerometer.xAddress) == 0)
        #expect(huge.read(MBC7Accelerometer.yAddress) == 0xFFFF)
        // And the other way round.
        let hugeNegative = latched(gravity: SIMD3(-1000, -1000, 0))
        #expect(hugeNegative.read(MBC7Accelerometer.xAddress) == 0xFFFF)
        #expect(hugeNegative.read(MBC7Accelerometer.yAddress) == 0)
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

    @Test func theTiltRegisterHoldsThePlanarMagnitude() {
        // A 45 degree tilt of 1 g is 0.7071 g in each axis, so the magnitude is 1 g: 112 counts.
        let mapper = latched(gravity: SIMD3(0.70710678, 0.70710678, 0))
        #expect(mapper.read(MBC7Accelerometer.tiltAddress) == 112)
    }

    @Test func theRotationSensorRegisterIsNotImplemented() {
        let mapper = latched(gravity: SIMD3(0.5, 0.5, 0))
        #expect(mapper.read(MBC7Accelerometer.rotationAddress) == 0)
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

    @Test func theRegistersAreLittleEndian() {
        let mapper = latched(gravity: SIMD3(0.5, 0, 0))
        let value = mapper.read(MBC7Accelerometer.xAddress)
        #expect(mapper.readByte(MBC7Accelerometer.xAddress) == UInt8(truncatingIfNeeded: value))
        #expect(mapper.readByte(MBC7Accelerometer.xAddress + 1) == UInt8(truncatingIfNeeded: value >> 8))
    }

    @Test func writesOutsideTheLatchRegisterAreIgnored() {
        var mapper = MBC7Accelerometer(gravity: SIMD3(0.5, 0, 0))
        mapper.write(MBC7Accelerometer.xAddress, 0x00)
        mapper.write(MBC7Accelerometer.latchStatusAddress, 0xAA)
        #expect(mapper.read(MBC7Accelerometer.xAddress) == 0x81D0)
        #expect(mapper.read(MBC7Accelerometer.latchStatusAddress) == 0x00)
    }
}
