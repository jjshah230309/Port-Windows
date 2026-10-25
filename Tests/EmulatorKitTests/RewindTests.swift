import Testing
@testable import EmulatorKit

@Suite struct RewindTests {
    private func state(_ seed: Int, size: Int = 5_000) -> [UInt8] {
        // Mostly constant with a few bytes that depend on the seed, like a real machine state.
        var s = [UInt8](repeating: 0x11, count: size)
        s[0] = UInt8(truncatingIfNeeded: seed)
        s[size / 2] = UInt8(truncatingIfNeeded: seed * 7)
        s[size - 1] = UInt8(truncatingIfNeeded: seed &* 13)
        return s
    }

    @Test func stepsBackThroughEveryCapture() {
        var buffer = RewindBuffer(capacity: 100)
        let states = (0..<20).map { state($0) }
        for s in states { buffer.capture(s) }
        #expect(buffer.depth == 19)
        for expected in states.dropLast().reversed() { #expect(buffer.stepBack() == expected) }
        #expect(buffer.stepBack() == nil)
    }

    @Test func oldestHistoryIsDroppedAtCapacity() {
        var buffer = RewindBuffer(capacity: 5)
        let states = (0..<20).map { state($0) }
        for s in states { buffer.capture(s) }
        #expect(buffer.depth == 5)
        var restored: [[UInt8]] = []
        while let s = buffer.stepBack() { restored.append(s) }
        #expect(restored == Array(states[14..<19].reversed()))
    }

    @Test func changedSizeStartsOver() {
        var buffer = RewindBuffer(capacity: 10)
        buffer.capture(state(1))
        buffer.capture(state(2))
        buffer.capture(state(3, size: 100))
        #expect(buffer.depth == 0)
    }

    @Test func deltasAreSmall() {
        // 200 KB states that differ in three bytes must not cost 200 KB each.
        var buffer = RewindBuffer(capacity: 50)
        for i in 0..<50 { buffer.capture(state(i, size: 200_000)) }
        #expect(buffer.depth == 49)
        #expect(buffer.stepBack() == state(48, size: 200_000))
    }
}
