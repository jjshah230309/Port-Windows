import Foundation
import Testing
import EmulatorKit
@testable import ControllerModel

/// The golden controller traces: the text format, the replay, and the run-ahead check.
///
/// The fixture is found relative to this file, because the package declares no resources and
/// SwiftPM will not let a test target claim a file outside its own directory.
@Suite struct GoldenTraceTests {

    // MARK: - The fixture

    /// The shipped fixture, read from disk.
    private static func fixtureText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ControllerModelTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/Traces/attic-golden-v1.txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The shipped fixture, parsed.
    private static func fixture() throws -> GoldenTrace {
        try GoldenTrace.parse(fixtureText())
    }

    // MARK: - The text format

    @Test func theHeaderIsTheFirstLine() throws {
        let trace = try Self.fixture()
        let lines = trace.serialized().split(separator: "\n")
        #expect(String(lines[0]) == GoldenTrace.header)
        #expect(String(lines[0]) == "attic-golden-trace 1")
    }

    @Test func theTextFormatRoundTrips() throws {
        var input = RawControllerState()
        input.buttons = PadButtons([.east, .l1]).rawValue
        input.leftStick = SIMD2(0.25, -0.75)
        input.rightStick = SIMD2(-0.5, 0.125)
        input.leftTrigger = 0.5
        input.rightTrigger = 0.75
        input.gravity = SIMD3(0.1, -0.2, 0.9)
        input.rotationRate = SIMD3(1.5, 0, -0.25)

        var expected = InputSnapshot()
        expected.buttons = PadButtons([.east])
        expected.leftStick = SIMD2(0.2, -0.6)
        expected.leftTrigger = 0.5

        let trace = GoldenTrace(frames: [GoldenTrace.Frame(input: input, expected: expected)])
        let parsed = try GoldenTrace.parse(trace.serialized())
        #expect(parsed == trace)
        #expect(parsed.frames.count == 1)
        #expect(parsed.frames[0].input.buttons == input.buttons)
        #expect(parsed.frames[0].input.leftStick == input.leftStick)
        #expect(parsed.frames[0].expected == expected)
    }

    @Test func theSettingsSurviveTheRoundTrip() throws {
        let settings = PipelineSettings(
            leftStick: StickConfig(innerDeadzone: 0.21, outerDeadzone: 0.83),
            rightStick: StickConfig(innerDeadzone: 0.05, outerDeadzone: 0.77),
            leftCurve: .eased,
            rightCurve: .aggressive,
            leftTriggerPressAt: 0.42,
            leftTriggerReleaseAt: 0.11,
            rightTriggerPressAt: 0.63,
            rightTriggerReleaseAt: 0.22,
            stickAsDPad: true,
            stickAsDPadGate: 0.44,
            turbo: [.east: TurboSetting(period: 3, phaseOffset: 1)]
        )
        let trace = GoldenTrace(settings: settings)
        let parsed = try GoldenTrace.parse(trace.serialized())
        #expect(parsed.settings == settings)
        #expect(parsed.settings.leftCurve == .eased)
        #expect(parsed.settings.rightCurve == .aggressive)
        #expect(parsed.settings.stickAsDPadGate == 0.44)
        #expect(parsed.settings.turbo[.east] == TurboSetting(period: 3, phaseOffset: 1))
    }

    @Test func aFrameLineCarriesTheInputAndTheExpectedOutput() throws {
        let trace = try Self.fixture()
        let lines = trace.serialized().split(separator: "\n")
        // The header, the settings, then one line per frame.
        #expect(lines.count == trace.frames.count + 2)
        let parts = String(lines[2]).split(separator: " ").map(String.init)
        #expect(parts.first == "frame")
        // Thirteen numbers on the input side, the arrow, then thirteen on the output side.
        #expect(parts.count == 1 + 13 + 1 + 13)
        #expect(parts[14] == "->")
        // The button masks are written as sixteen hex digits, so the columns line up.
        #expect(parts[1].count == 16)
        #expect(parts[15].count == 16)
        #expect(UInt64(parts[1], radix: 16) != nil)
    }

    @Test func theTraceIsCodable() throws {
        let trace = try Self.fixture()
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(GoldenTrace.self, from: data)
        #expect(decoded == trace)
        #expect(decoded.frames.count == trace.frames.count)
        #expect(decoded.settings == trace.settings)
    }

    // MARK: - The replay

    @Test func theReplayProducesTheExpectedSnapshots() throws {
        // A hand-built trace: the value below is what the pipeline's documented rules say the
        // output has to be, worked out here rather than copied out of the implementation.
        var pipeline = InputPipeline()
        pipeline.leftStick = StickConfig(innerDeadzone: 0.12, outerDeadzone: 0.97)

        var input = RawControllerState()
        input.leftStick = SIMD2(0.50, 0)
        // The deadzone scales the travel: (0.50 - 0.12) / (0.97 - 0.12).
        let scaled: Float = (0.50 - 0.12) / (0.97 - 0.12)

        var expected = InputSnapshot()
        expected.leftStick = SIMD2(scaled, 0)

        let trace = GoldenTrace(frames: [GoldenTrace.Frame(input: input, expected: expected)])
        let replayed = trace.replay(through: pipeline)
        #expect(replayed.count == 1)
        #expect(abs(replayed[0].leftStick.x - scaled) < 1e-6)
        #expect(replayed[0].leftStick.y == 0)
        #expect(replayed[0].buttons == [])
        // The replay agrees with what the trace recorded, which is the point of a golden trace.
        #expect(trace.replaysToRecordedOutput(through: pipeline))
    }

    @Test func theReplayCarriesTheTriggerStateBetweenFrames() {
        var pipeline = InputPipeline()
        pipeline.leftTrigger = TriggerHysteresis(pressAt: 0.35, releaseAt: 0.25)

        var frames: [GoldenTrace.Frame] = []
        for value in [Float(0.20), 0.35, 0.28, 0.15, 0.30] {
            var input = RawControllerState()
            input.leftTrigger = value
            frames.append(GoldenTrace.Frame(input: input, expected: InputSnapshot()))
        }
        let trace = GoldenTrace(frames: frames)
        let replayed = trace.replay(through: pipeline)

        // 0.20 is under the press threshold, 0.35 crosses it, 0.28 sits in the band and keeps
        // the trigger pressed, 0.15 drops under the release threshold, and 0.30 is under the
        // press threshold again so the trigger stays released.
        #expect(replayed.map { $0.buttons.contains(.l2) } == [false, true, true, false, false])
    }

    @Test func theReplayCarriesTheTurboPhaseBetweenFrames() {
        var pipeline = InputPipeline()
        pipeline.turbo = [.east: TurboSetting(period: 2, phaseOffset: 0)]

        var frames: [GoldenTrace.Frame] = []
        for _ in 0..<6 {
            var input = RawControllerState()
            input.buttons = PadButtons([.east]).rawValue
            frames.append(GoldenTrace.Frame(input: input, expected: InputSnapshot()))
        }
        let trace = GoldenTrace(frames: frames)
        let replayed = trace.replay(through: pipeline)
        // Two frames on, two frames off.
        #expect(replayed.map { $0.buttons.contains(.east) } == [true, true, false, false, true, true])
    }

    @Test func theReplayNeutralisesOpposingButtons() {
        let pipeline = InputPipeline()
        var input = RawControllerState()
        input.buttons = PadButtons([.up, .down, .left, .right]).rawValue
        let trace = GoldenTrace(frames: [GoldenTrace.Frame(input: input, expected: InputSnapshot())])
        let replayed = trace.replay(through: pipeline)
        #expect(replayed[0].buttons == [])
    }

    // MARK: - The run-ahead check

    @Test func theRunAheadOutputEqualsTheNormalOutput() throws {
        let trace = try Self.fixture()
        let pipeline = trace.pipeline()
        #expect(trace.runAhead(through: pipeline) == trace.replay(through: pipeline))
        #expect(trace.runAheadEqualsNormal(trace, pipeline: pipeline))
        // The run-ahead path reproduces the recorded session, frame for frame.
        #expect(trace.runAhead(through: pipeline) == trace.expectedSnapshots)
    }

    @Test func theRunAheadCheckFailsWhenTheTraceIsTamperedWith() throws {
        let trace = try Self.fixture()
        let pipeline = trace.pipeline()

        // Change one frame's input, so the candidate no longer describes the recorded session.
        var tampered = trace
        var input = tampered.frames[10].input
        input.leftTrigger = 0.95
        tampered.frames[10] = GoldenTrace.Frame(input: input, expected: tampered.frames[10].expected)

        #expect(!trace.runAheadEqualsNormal(tampered, pipeline: pipeline))
        // The mismatch is named, so a broken trace says which frame went wrong.
        #expect(tampered.firstMismatch(through: pipeline) == 10)
        #expect(!tampered.replaysToRecordedOutput(through: pipeline))
    }

    @Test func theRunAheadCheckFailsWhenTheExpectedOutputIsWrong() throws {
        let trace = try Self.fixture()
        let pipeline = trace.pipeline()
        var wrong = trace
        var expected = wrong.frames[4].expected
        expected.buttons.insert(.home)
        wrong.frames[4] = GoldenTrace.Frame(input: wrong.frames[4].input, expected: expected)
        #expect(!wrong.replaysToRecordedOutput(through: pipeline))
        #expect(wrong.firstMismatch(through: pipeline) == 4)
    }

    // MARK: - The shipped fixture

    @Test func theFixtureIsLongEnoughAndParses() throws {
        let trace = try Self.fixture()
        #expect(trace.frames.count >= 30)
        #expect(trace.serialized().hasSuffix("\n"))
    }

    @Test func theFixtureReplaysToItsOwnExpectedOutput() throws {
        let trace = try Self.fixture()
        let pipeline = trace.pipeline()
        #expect(trace.replaysToRecordedOutput(through: pipeline))
        #expect(trace.firstMismatch(through: pipeline) == nil)
        #expect(trace.replay(through: pipeline).count == trace.frames.count)
    }

    @Test func theFixtureExercisesTheDeadzone() throws {
        let trace = try Self.fixture()
        let replayed = trace.replay(through: trace.pipeline())
        // The first frame pushes the stick to 0.10, inside the 0.15 deadzone, so it reads zero.
        #expect(trace.frames[0].input.leftStick.x == 0.10)
        #expect(replayed[0].leftStick == .zero)
        // The fourth frame pushes to 0.30, which scales to (0.30 - 0.15) / (0.95 - 0.15).
        #expect(abs(replayed[3].leftStick.x - (0.30 - 0.15) / (0.95 - 0.15)) < 1e-6)
        // The right stick has its own deadzone, and 0.10 is inside it too.
        #expect(replayed[6].rightStick == .zero)
        // And 0.40 is outside it, so the right stick does read.
        #expect(replayed[7].rightStick.x != 0)
    }

    @Test func theFixtureExercisesTheTriggerThreshold() throws {
        let trace = try Self.fixture()
        let replayed = trace.replay(through: trace.pipeline())
        // The left trigger crosses 0.30 at frame 14 and stays pressed at 0.28, then releases.
        #expect(!replayed[13].buttons.contains(.l2))
        #expect(replayed[14].buttons.contains(.l2))
        #expect(replayed[15].buttons.contains(.l2))
        #expect(!replayed[16].buttons.contains(.l2))
        // The right trigger has its own threshold at 0.50.
        #expect(!replayed[17].buttons.contains(.r2))
        #expect(replayed[18].buttons.contains(.r2))
    }

    @Test func theFixtureExercisesTheSoCD() throws {
        let trace = try Self.fixture()
        let replayed = trace.replay(through: trace.pipeline())
        // Frame 9 holds up and down at once, and frame 10 holds left and right at once.
        #expect(trace.frames[9].input.buttons == PadButtons([.up, .down]).rawValue)
        #expect(replayed[9].buttons == [])
        #expect(trace.frames[10].input.buttons == PadButtons([.left, .right]).rawValue)
        #expect(replayed[10].buttons == [])
        // A frame with no conflict comes through untouched.
        #expect(replayed[11].buttons == [.up])
    }

    @Test func theFixtureExercisesTheDPadGate() throws {
        let trace = try Self.fixture()
        let replayed = trace.replay(through: trace.pipeline())
        // The gate is 0.55. The stick at 0.60 is past it and reads as a d-pad press.
        #expect(replayed[4].buttons == [.right])
        // The diagonal at 0.70/0.70 is past it too, and reads as up and right.
        #expect(replayed[30].buttons == [.up, .right])
        // The diagonal at 0.40/0.40 is under the gate, so it drives no button at all.
        #expect(replayed[31].buttons == [])
    }

    @Test func theFixtureExercisesTheTurboButton() throws {
        let trace = try Self.fixture()
        let replayed = trace.replay(through: trace.pipeline())
        // Frames 20 to 25 hold the east button, which is on a period of two: on, on, off, off.
        #expect(replayed[20].buttons.contains(.east))
        #expect(replayed[21].buttons.contains(.east))
        #expect(!replayed[22].buttons.contains(.east))
        #expect(!replayed[23].buttons.contains(.east))
        #expect(replayed[24].buttons.contains(.east))
        #expect(replayed[25].buttons.contains(.east))
        // The north button runs on a period of three, so it is on a different rhythm: of the
        // four frames that hold it, only the last one has it pressed.
        #expect(!replayed[26].buttons.contains(.north))
        #expect(!replayed[27].buttons.contains(.north))
        #expect(!replayed[28].buttons.contains(.north))
        #expect(replayed[29].buttons.contains(.north))
    }

    // MARK: - A corrupted fixture

    @Test func aCorruptedHeaderIsRejected() {
        #expect(throws: GoldenTraceError.badHeader) {
            _ = try GoldenTrace.parse("nonsense\n")
        }
    }

    @Test func aCorruptedFrameLineIsRejected() throws {
        var lines = try Self.fixtureText().split(separator: "\n").map(String.init)
        lines[4] = "frame 0000000000000000 0.0 0.0"   // too few numbers
        #expect(throws: GoldenTraceError.badFrame(line: 5)) {
            _ = try GoldenTrace.parse(lines.joined(separator: "\n") + "\n")
        }
    }

    @Test func aCorruptedSettingsLineIsRejected() throws {
        var lines = try Self.fixtureText().split(separator: "\n").map(String.init)
        lines[1] = "settings stick-l=broken"
        #expect(throws: GoldenTraceError.badSettings(line: 2)) {
            _ = try GoldenTrace.parse(lines.joined(separator: "\n") + "\n")
        }
    }

    @Test func theErrorSaysWhereTheTraceWentWrong() {
        let error = GoldenTraceError.badFrame(line: 7)
        #expect(error.description.contains("7"))
        #expect(GoldenTraceError.badHeader.description.contains("attic-golden-trace"))
    }
}
