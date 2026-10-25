import Testing
import EmulatorKit
@testable import ControllerModel

@Suite struct InputPipelineRunnerTests {
    @Test func theFrameCounterAdvancesWithEachFrame() {
        var runner = InputPipelineRunner()
        #expect(runner.framesProcessed == 0)
        runner.process(RawControllerState())
        #expect(runner.framesProcessed == 1)
        runner.process(RawControllerState())
        #expect(runner.framesProcessed == 2)
    }

    @Test func turboCyclesAcrossFrames() {
        var pipeline = InputPipeline()
        pipeline.turbo = [.east: TurboSetting(period: 2)]
        var runner = InputPipelineRunner(pipeline: pipeline)

        var raw = RawControllerState()
        raw.buttons = PadButtons([.east]).rawValue

        // Period 2 means two frames on and two frames off.
        #expect(runner.process(raw).buttons.contains(.east))
        #expect(runner.process(raw).buttons.contains(.east))
        #expect(!runner.process(raw).buttons.contains(.east))
        #expect(!runner.process(raw).buttons.contains(.east))
        #expect(runner.process(raw).buttons.contains(.east))
    }

    @Test func theTriggerStaysPressedBetweenTheThresholds() {
        var runner = InputPipelineRunner()
        var raw = RawControllerState()

        raw.leftTrigger = 0.30
        #expect(!runner.process(raw).buttons.contains(.l2))
        raw.leftTrigger = 0.40
        #expect(runner.process(raw).buttons.contains(.l2))
        // Between the release and the press threshold it must stay pressed.
        raw.leftTrigger = 0.30
        #expect(runner.process(raw).buttons.contains(.l2))
        raw.leftTrigger = 0.20
        #expect(!runner.process(raw).buttons.contains(.l2))
        raw.leftTrigger = 0.30
        #expect(!runner.process(raw).buttons.contains(.l2))
    }

    @Test func theTriggerStateSurvivesTheFrameBoundary() {
        // A pipeline read into a local copy for each frame would reset the trigger every time,
        // so a value in the dead band would never stay pressed.
        var runner = InputPipelineRunner()
        var raw = RawControllerState()
        raw.rightTrigger = 0.9
        #expect(runner.process(raw).buttons.contains(.r2))
        raw.rightTrigger = 0.30
        #expect(runner.process(raw).buttons.contains(.r2))
    }

    @Test func changingTheSettingsKeepsTheFrameCounter() {
        var pipeline = InputPipeline()
        pipeline.turbo = [.east: TurboSetting(period: 2)]
        var runner = InputPipelineRunner(pipeline: pipeline)
        runner.process(RawControllerState())
        runner.process(RawControllerState())
        #expect(runner.framesProcessed == 2)

        var updated = InputPipeline()
        updated.turbo = [.east: TurboSetting(period: 2)]
        runner.update(pipeline: updated)
        #expect(runner.framesProcessed == 2)

        // The turbo phase is relative to the frame, so the next frames stay in the rhythm.
        var raw = RawControllerState()
        raw.buttons = PadButtons([.east]).rawValue
        #expect(!runner.process(raw).buttons.contains(.east))
    }

    @Test func theSameInputGivesTheSameOutputEveryTime() {
        var a = InputPipelineRunner()
        var b = InputPipelineRunner()
        for _ in 0..<10 {
            var raw = RawControllerState()
            raw.leftStick = SIMD2(0.6, -0.2)
            raw.leftTrigger = 0.5
            #expect(a.process(raw) == b.process(raw))
        }
    }
}
