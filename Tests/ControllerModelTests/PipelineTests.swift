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

    @Test func responseCurveChangesTravelButNotDirection() {
        var p = InputPipeline()
        p.leftCurve = .aggressive
        var raw = RawControllerState()
        raw.leftStick = SIMD2(0.5, 0)
        let out = p.process(raw)
        // Linear would give 0.5 after the deadzone; the cubic curve pulls it in.
        #expect(out.leftStick.x < 0.5)
        #expect(out.leftStick.x > 0)
        #expect(out.leftStick.y == 0)
    }

    @Test func linearCurveIsTheDefaultAndChangesNothing() {
        var p = InputPipeline()
        var raw = RawControllerState()
        raw.leftStick = SIMD2(0.5, 0)
        let out = p.process(raw)
        let expected = Deadzone.radial(SIMD2(0.5, 0), inner: 0.12, outer: 0.97)
        #expect(abs(out.leftStick.x - expected.x) < 0.0001)
    }

    @Test func turboPressesOnlyOnItsFrames() {
        var p = InputPipeline()
        p.turbo = [.east: TurboSetting(period: 2, phaseOffset: 0)]
        var raw = RawControllerState()
        raw.buttons = PadButtons([.east]).rawValue
        // period 2 means 2 frames on, 2 frames off.
        #expect(p.process(raw, frame: 0).buttons.contains(.east))
        #expect(p.process(raw, frame: 1).buttons.contains(.east))
        #expect(!p.process(raw, frame: 2).buttons.contains(.east))
        #expect(!p.process(raw, frame: 3).buttons.contains(.east))
        #expect(p.process(raw, frame: 4).buttons.contains(.east))
    }

    @Test func turboLeavesOtherButtonsHeld() {
        var p = InputPipeline()
        p.turbo = [.east: TurboSetting(period: 2)]
        var raw = RawControllerState()
        raw.buttons = PadButtons([.east, .south]).rawValue
        let out = p.process(raw, frame: 2)
        #expect(!out.buttons.contains(.east))
        #expect(out.buttons.contains(.south))
    }

    @Test func turboWithNoPeriodIsSimplyHeld() {
        var p = InputPipeline()
        p.turbo = [.east: TurboSetting(period: 0)]
        var raw = RawControllerState()
        raw.buttons = PadButtons([.east]).rawValue
        for frame in 0..<5 {
            #expect(p.process(raw, frame: frame).buttons.contains(.east))
        }
    }

    @Test func turboPhaseOffsetDecouplesTwoButtons() {
        var p = InputPipeline()
        p.turbo = [.east: TurboSetting(period: 2, phaseOffset: 0),
                   .south: TurboSetting(period: 2, phaseOffset: 2)]
        var raw = RawControllerState()
        raw.buttons = PadButtons([.east, .south]).rawValue
        // At frame 0 the east button is on and the south one is off.
        let out = p.process(raw, frame: 0)
        #expect(out.buttons.contains(.east))
        #expect(!out.buttons.contains(.south))
    }

    @Test func stickAsDPadAddsDirections() {
        var p = InputPipeline()
        p.stickAsDPad = true
        var raw = RawControllerState()
        raw.leftStick = SIMD2(0, 1)
        #expect(p.process(raw).buttons.contains(.up))
        var p2 = InputPipeline()
        p2.stickAsDPad = false
        #expect(!p2.process(raw).buttons.contains(.up))
    }

    @Test func stickAsDPadRespectsItsGate() {
        var p = InputPipeline()
        p.stickAsDPad = true
        p.stickAsDPadGate = 0.5
        var raw = RawControllerState()
        raw.leftStick = SIMD2(0, 0.3)     // under the gate
        #expect(!p.process(raw).buttons.contains(.up))
        raw.leftStick = SIMD2(0, 0.8)    // over the gate
        #expect(p.process(raw).buttons.contains(.up))
    }
}
