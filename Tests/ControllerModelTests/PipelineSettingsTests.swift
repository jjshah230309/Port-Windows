import Foundation
import Testing
import EmulatorKit
@testable import ControllerModel

@Suite struct PipelineSettingsTests {
    // MARK: - Defaults

    @Test func theDefaultsMatchThePipelineDefaults() {
        let settings = PipelineSettings()
        #expect(settings.leftStick.innerDeadzone == 0.12)
        #expect(settings.leftStick.outerDeadzone == 0.97)
        #expect(settings.rightStick.innerDeadzone == 0.12)
        #expect(settings.rightStick.outerDeadzone == 0.97)
        #expect(settings.leftCurve == .linear)
        #expect(settings.rightCurve == .linear)
        #expect(settings.leftTriggerPressAt == 0.35)
        #expect(settings.leftTriggerReleaseAt == 0.25)
        #expect(settings.rightTriggerPressAt == 0.35)
        #expect(settings.rightTriggerReleaseAt == 0.25)
        #expect(settings.stickAsDPad == false)
        #expect(settings.stickAsDPadGate == 0.5)
        #expect(settings.turbo.isEmpty)
    }

    @Test func theDefaultsMatchAFreshPipeline() {
        let settings = PipelineSettings()
        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)

        let reference = InputPipeline()
        #expect(pipeline.leftStick == reference.leftStick)
        #expect(pipeline.rightStick == reference.rightStick)
        #expect(pipeline.leftCurve == reference.leftCurve)
        #expect(pipeline.rightCurve == reference.rightCurve)
        #expect(pipeline.leftTrigger.pressAt == reference.leftTrigger.pressAt)
        #expect(pipeline.leftTrigger.releaseAt == reference.leftTrigger.releaseAt)
        #expect(pipeline.rightTrigger.pressAt == reference.rightTrigger.pressAt)
        #expect(pipeline.rightTrigger.releaseAt == reference.rightTrigger.releaseAt)
        #expect(pipeline.stickAsDPad == reference.stickAsDPad)
        #expect(pipeline.stickAsDPadGate == reference.stickAsDPadGate)
        #expect(pipeline.turbo == reference.turbo)
    }

    // MARK: - Round trips

    @Test func theDefaultsSurviveARoundTrip() throws {
        let settings = PipelineSettings()
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func everyFieldSurvivesARoundTrip() throws {
        var settings = PipelineSettings()
        settings.leftStick = StickConfig(innerDeadzone: 0.05, outerDeadzone: 0.8)
        settings.rightStick = StickConfig(innerDeadzone: 0.2, outerDeadzone: 1.0)
        settings.leftCurve = .eased
        settings.rightCurve = .aggressive
        settings.leftTriggerPressAt = 0.6
        settings.leftTriggerReleaseAt = 0.4
        settings.rightTriggerPressAt = 0.7
        settings.rightTriggerReleaseAt = 0.1
        settings.stickAsDPad = true
        settings.stickAsDPadGate = 0.75
        settings.turbo = [.east: TurboSetting(period: 6, phaseOffset: 3)]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.leftStick.innerDeadzone == 0.05)
        #expect(decoded.rightStick.outerDeadzone == 1.0)
        #expect(decoded.leftCurve == .eased)
        #expect(decoded.rightCurve == .aggressive)
        #expect(decoded.leftTriggerPressAt == 0.6)
        #expect(decoded.rightTriggerReleaseAt == 0.1)
        #expect(decoded.stickAsDPadGate == 0.75)
        #expect(decoded.turbo[.east] == TurboSetting(period: 6, phaseOffset: 3))
    }

    @Test func aTurboSettingSurvivesTheRoundTrip() throws {
        var settings = PipelineSettings()
        settings.turbo = [.south: TurboSetting(period: 4, phaseOffset: 2)]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: data)

        let setting = try #require(decoded.turbo[.south])
        #expect(setting.period == 4)
        #expect(setting.phaseOffset == 2)
    }

    @Test func theSettingsSurviveARestart() throws {
        var settings = PipelineSettings()
        settings.leftCurve = .aggressive
        settings.turbo = [.north: TurboSetting(period: 8, phaseOffset: 1)]

        // Written out and read back, as a restart would.
        let data = try JSONEncoder.sorted.encode(settings)
        let reloaded = try JSONDecoder().decode(PipelineSettings.self, from: data)

        #expect(reloaded == settings)
        // And written out again, so the file does not drift between runs.
        #expect(try JSONEncoder.sorted.encode(reloaded) == data)
    }

    // MARK: - Decoding

    @Test func anUnknownKeyDoesNotBreakTheDecoding() throws {
        let json = """
        {
          "leftCurve": "eased",
          "somethingNew": 42,
          "turbo": [ { "button": "east", "period": 3, "phaseOffset": 1, "extra": true } ]
        }
        """
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: Data(json.utf8))
        #expect(decoded.leftCurve == .eased)
        #expect(decoded.turbo[.east] == TurboSetting(period: 3, phaseOffset: 1))
    }

    @Test func missingKeysFallBackToTheDefaults() throws {
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: Data("{}".utf8))
        #expect(decoded == PipelineSettings())
    }

    @Test func aPartlyFilledDocumentKeepsTheDefaultsForTheRest() throws {
        let json = """
        {
          "leftStick": { "innerDeadzone": 0.3 },
          "rightCurve": "aggressive",
          "rightTriggerPressAt": 0.8
        }
        """
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: Data(json.utf8))
        #expect(decoded.leftStick.innerDeadzone == 0.3)
        #expect(decoded.leftStick.outerDeadzone == 0.97)
        #expect(decoded.rightStick == StickConfig())
        #expect(decoded.rightCurve == .aggressive)
        #expect(decoded.leftCurve == .linear)
        #expect(decoded.rightTriggerPressAt == 0.8)
        #expect(decoded.leftTriggerPressAt == 0.35)
        #expect(decoded.stickAsDPad == false)
        #expect(decoded.turbo.isEmpty)
    }

    @Test func anUnknownTurboButtonNameIsSkippedRatherThanFatal() throws {
        let json = """
        { "turbo": [ { "button": "someNewButton", "period": 3, "phaseOffset": 0 },
                     { "button": "east", "period": 2, "phaseOffset": 0 } ] }
        """
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: Data(json.utf8))
        #expect(decoded.turbo.count == 1)
        #expect(decoded.turbo[.east] == TurboSetting(period: 2))
    }

    // MARK: - Applying

    @Test func applyingTheSettingsChangesThePipeline() {
        var settings = PipelineSettings()
        settings.leftStick = StickConfig(innerDeadzone: 0.02, outerDeadzone: 0.9)
        settings.rightStick = StickConfig(innerDeadzone: 0.25, outerDeadzone: 1.0)
        settings.leftCurve = .eased
        settings.rightCurve = .aggressive
        settings.leftTriggerPressAt = 0.6
        settings.leftTriggerReleaseAt = 0.45
        settings.rightTriggerPressAt = 0.55
        settings.rightTriggerReleaseAt = 0.2
        settings.stickAsDPad = true
        settings.stickAsDPadGate = 0.8
        settings.turbo = [.east: TurboSetting(period: 2)]

        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)

        #expect(pipeline.leftStick.innerDeadzone == 0.02)
        #expect(pipeline.leftStick.outerDeadzone == 0.9)
        #expect(pipeline.rightStick.innerDeadzone == 0.25)
        #expect(pipeline.rightStick.outerDeadzone == 1.0)
        #expect(pipeline.leftCurve == .eased)
        #expect(pipeline.rightCurve == .aggressive)
        #expect(pipeline.leftTrigger.pressAt == 0.6)
        #expect(pipeline.leftTrigger.releaseAt == 0.45)
        #expect(pipeline.rightTrigger.pressAt == 0.55)
        #expect(pipeline.rightTrigger.releaseAt == 0.2)
        #expect(pipeline.stickAsDPad == true)
        #expect(pipeline.stickAsDPadGate == 0.8)
        #expect(pipeline.turbo[.east] == TurboSetting(period: 2))
    }

    @Test func applyingTheSettingsChangesWhatTheGameSees() {
        var settings = PipelineSettings()
        settings.leftStick = StickConfig(innerDeadzone: 0.3, outerDeadzone: 0.9)
        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)

        var raw = RawControllerState()
        raw.leftStick = SIMD2(0.2, 0)
        // The old deadzone would have let this through; the new one swallows it.
        #expect(pipeline.process(raw).leftStick == .zero)

        raw.leftStick = SIMD2(0.9, 0)
        #expect(pipeline.process(raw).leftStick.x > 0.5)
    }

    @Test func applyingTheSettingsMovesTheTriggerThresholds() {
        var settings = PipelineSettings()
        settings.leftTriggerPressAt = 0.95
        settings.leftTriggerReleaseAt = 0.9
        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)

        var raw = RawControllerState()
        raw.leftTrigger = 0.9
        #expect(!pipeline.process(raw).buttons.contains(.l2))
        raw.leftTrigger = 0.96
        #expect(pipeline.process(raw).buttons.contains(.l2))
    }

    @Test func applyingTheSettingsResetsTheTriggerState() {
        var pipeline = InputPipeline()
        var raw = RawControllerState()
        raw.leftTrigger = 0.9
        #expect(pipeline.process(raw).buttons.contains(.l2))

        // The thresholds have moved, so the trigger is measured again from scratch.
        var settings = PipelineSettings()
        settings.leftTriggerPressAt = 0.95
        settings.apply(to: &pipeline)
        #expect(!pipeline.process(raw).buttons.contains(.l2))
    }

    @Test func applyingTheSettingsToARunnerKeepsTheFrameCounter() {
        var pipeline = InputPipeline()
        pipeline.turbo = [.east: TurboSetting(period: 2)]
        var runner = InputPipelineRunner(pipeline: pipeline)
        runner.process(RawControllerState())
        runner.process(RawControllerState())
        #expect(runner.framesProcessed == 2)

        var settings = PipelineSettings()
        settings.turbo = [.east: TurboSetting(period: 2)]
        settings.apply(to: &runner)
        #expect(runner.framesProcessed == 2)

        // The turbo phase is relative to the frame, so the rhythm carries on.
        var raw = RawControllerState()
        raw.buttons = PadButtons([.east]).rawValue
        #expect(!runner.process(raw).buttons.contains(.east))
    }

    @Test func aButtonOutsideTheTurboDictionaryIsLeftAlone() {
        var settings = PipelineSettings()
        settings.turbo = [.east: TurboSetting(period: 2)]
        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)

        var raw = RawControllerState()
        raw.buttons = PadButtons([.east, .south]).rawValue
        // Frame 2 is an off frame for the turbo button; the other button is simply held.
        let out = pipeline.process(raw, frame: 2)
        #expect(!out.buttons.contains(.east))
        #expect(out.buttons.contains(.south))
    }

    @Test func theStickAsDPadGateIsApplied() {
        var settings = PipelineSettings()
        settings.stickAsDPad = true
        settings.stickAsDPadGate = 0.5
        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)

        var raw = RawControllerState()
        raw.leftStick = SIMD2(0, 0.8)
        #expect(pipeline.process(raw).buttons.contains(.up))

        settings.stickAsDPadGate = 0.9
        settings.apply(to: &pipeline)
        #expect(!pipeline.process(raw).buttons.contains(.up))
    }

    // MARK: - The file format

    @Test func theTurboButtonsAreWrittenByName() throws {
        var settings = PipelineSettings()
        settings.turbo = [.east: TurboSetting(period: 2, phaseOffset: 0)]
        let data = try JSONEncoder().encode(settings)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let turbo = try #require(json["turbo"] as? [[String: Any]])
        #expect(turbo.count == 1)
        #expect(turbo[0]["button"] as? String == "east")
        #expect(turbo[0]["period"] as? Int == 2)
    }

    @Test func theTurboButtonsAreWrittenInAFixedOrder() throws {
        var settings = PipelineSettings()
        settings.turbo = [.south: TurboSetting(period: 2),
                          .east: TurboSetting(period: 2),
                          .north: TurboSetting(period: 2)]
        let data = try JSONEncoder().encode(settings)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let turbo = try #require(json["turbo"] as? [[String: Any]])
        let names = turbo.compactMap { $0["button"] as? String }
        #expect(names == ["east", "north", "south"])
    }

    @Test func theSameSettingsEncodeToTheSameBytesEveryTime() throws {
        var settings = PipelineSettings()
        settings.leftCurve = .eased
        settings.turbo = [.east: TurboSetting(period: 2, phaseOffset: 1),
                          [.south, .north]: TurboSetting(period: 4)]

        // Two encoders, because a keyed container can be written out in any order.
        let first = try JSONEncoder.sorted.encode(settings)
        let second = try JSONEncoder.sorted.encode(settings)
        #expect(first == second)

        // And the same bytes after a trip through the decoder.
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: first)
        #expect(try JSONEncoder.sorted.encode(decoded) == first)
    }

    @Test func theButtonNamesAreStable() {
        #expect(PadButtons.up.name == "up")
        #expect(PadButtons.touchpadClick.name == "touchpadClick")
        #expect(PadButtons([.up, .right]).name == "up+right")
        #expect(PadButtons.buttons(named: "east") == .east)
        #expect(PadButtons.buttons(named: "up+right") == [.up, .right])
        #expect(PadButtons.buttons(named: "nonsense") == [])
    }
}

private extension JSONEncoder {
    /// The settings must always write out the same bytes, so the keys are sorted.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
