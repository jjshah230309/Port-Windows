import Testing
import EmulatorKit
@testable import ControllerModel

@Suite struct PipelineTests {
    @Test func deadzoneSwallowsSmallInput() {
        #expect(Deadzone.radial(SIMD2(0.05, -0.05), inner: 0.12, outer: 0.97) == .zero)
    }

    @Test func deadzoneRescalesAndClamps() {
        let mid = Deadzone.radial(SIMD2(0.545, 0), inner: 0.12, outer: 0.97)
        #expect(abs(mid.x - 0.5) < 0.001)
        let full = Deadzone.radial(SIMD2(0.7, 0.7), inner: 0.12, outer: 0.97)
        let len = (full * full).sum().squareRoot()
        #expect(abs(len - 1) < 0.001)
    }

    @Test func triggerHysteresis() {
        var t = TriggerHysteresis()
        #expect(t.update(0.30) == false)
        #expect(t.update(0.40) == true)
        #expect(t.update(0.30) == true)   // between release and press: stays pressed
        #expect(t.update(0.20) == false)
        #expect(t.update(0.30) == false)  // between release and press: stays released
    }

    @Test func stickToDPadOctants() {
        #expect(StickToDPad.buttons(for: SIMD2(0, 1)) == [.up])
        #expect(StickToDPad.buttons(for: SIMD2(1, 0)) == [.right])
        #expect(StickToDPad.buttons(for: SIMD2(0.8, 0.8)) == [.up, .right])
        #expect(StickToDPad.buttons(for: SIMD2(-0.8, -0.8)) == [.down, .left])
        #expect(StickToDPad.buttons(for: SIMD2(0.2, 0.2)) == [])
    }

    @Test func socdCancelsOpposites() {
        #expect(SOCD.neutral([.up, .down, .east]) == [.east])
        #expect(SOCD.neutral([.left, .right]) == [])
        #expect(SOCD.neutral([.up, .left]) == [.up, .left])
    }

    @Test func pipelineAppliesAllStages() {
        var p = InputPipeline()
        var raw = RawControllerState()
        raw.buttons = PadButtons([.south, .up, .down]).rawValue
        raw.leftStick = SIMD2(1, 0)
        raw.rightTrigger = 0.9
        let out = p.process(raw)
        #expect(out.buttons.contains(.south))
        #expect(!out.buttons.contains(.up) && !out.buttons.contains(.down))
        #expect(out.buttons.contains(.r2))
        #expect(out.leftStick.x == 1)
    }
}
