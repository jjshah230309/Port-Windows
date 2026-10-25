import EmulatorKit

/// A recorded controller session with the output it must produce: the pipeline settings that
/// were in force, the raw input of every frame, and the `InputSnapshot` the pipeline produced
/// for that frame.
///
/// The text form is one line per frame, so a diff of two sessions reads like a bug report.
///
/// # The text format
///
///     attic-golden-trace 1
///     settings stick-l=0.1/0.9 stick-r=0.12/0.97 curve-l=eased curve-r=linear
///              trigger-l=0.4/0.3 trigger-r=0.35/0.25 stick-as-dpad=1 dpad-gate=0.35
///              turbo=north:2:0,east:3:1
///     frame <input> -> <output>
///
/// The first line is the header. The second line is the pipeline settings that were in force,
/// written as `key=value` pairs so a settings change shows up as a one-line diff. Every line
/// after that is one frame: the raw input, an arrow, and the expected output.
///
/// A frame line holds thirteen numbers on each side of the arrow, in this order:
///
///     buttons lx ly rx ry lt rt gx gy gz wx wy wz
///
/// `buttons` is a zero-padded 16-digit hex mask; the sticks are `x` then `y`; the triggers are
/// analog travel; `g` is gravity in g and `w` is the angular rate in rad/s, both relative to
/// the neutral pose. The right-hand side is the same list for the snapshot the pipeline must
/// produce. Every number is written with Swift's own shortest round-tripping description, so
/// parsing a line back gives the same bits.
///
/// The format records what the input pipeline consumes. Touch points, the battery level and
/// the sample timestamp are host-side facts the pipeline never reads, so they are not recorded.
public struct GoldenTrace: Codable, Equatable, Sendable {

    /// One frame of a recorded session: the raw input and the output it must produce.
    ///
    /// A frame records what the input pipeline consumes: the buttons, the two sticks, the two
    /// triggers and the motion. The other fields of `RawControllerState` - the touch points,
    /// the battery level and the sample timestamp - are host-side facts the pipeline never
    /// reads, so they are not part of the frame and are not compared.
    public struct Frame: Codable, Equatable, Sendable {
        /// The raw controller state for the frame, as the pipeline's caller sees it.
        public var input: RawControllerState
        /// The snapshot the pipeline must produce for this frame.
        public var expected: InputSnapshot

        public init(input: RawControllerState, expected: InputSnapshot) {
            self.input = input
            self.expected = expected
        }

        /// The raw state, with the fields the pipeline reads.
        public var buttons: UInt64 { input.buttons }
        public var leftStick: SIMD2<Float> { input.leftStick }
        public var rightStick: SIMD2<Float> { input.rightStick }
        public var leftTrigger: Float { input.leftTrigger }
        public var rightTrigger: Float { input.rightTrigger }
        public var gravity: SIMD3<Float> { input.gravity }
        public var rotationRate: SIMD3<Float> { input.rotationRate }

        /// Two frames are the same when they record the same thing. Only the recorded fields
        /// count, so a frame read back from the text form equals the one that was written.
        public static func == (a: Frame, b: Frame) -> Bool {
            a.buttons == b.buttons
                && a.leftStick == b.leftStick
                && a.rightStick == b.rightStick
                && a.leftTrigger == b.leftTrigger
                && a.rightTrigger == b.rightTrigger
                && a.gravity == b.gravity
                && a.rotationRate == b.rotationRate
                && a.expected == b.expected
        }
    }

    /// The pipeline settings that were in force when the session was recorded.
    public var settings: PipelineSettings
    /// The recorded frames, in order.
    public var frames: [Frame]

    public init(settings: PipelineSettings = PipelineSettings(), frames: [Frame] = []) {
        self.settings = settings
        self.frames = frames
    }

    // MARK: - Text form

    /// The header line every golden trace starts with.
    public static let header = "attic-golden-trace 1"

    /// The trace as text: a header, the settings, then one line per frame.
    public func serialized() -> String {
        var lines = [Self.header, settingsLine()]
        for frame in frames {
            lines.append(Self.frameLine(frame))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a trace back from its text form.
    ///
    /// Throws a `GoldenTraceError` with the line number when a line cannot be read, so a
    /// corrupted fixture says where it went wrong rather than just failing.
    public static func parse(_ text: String) throws -> GoldenTrace {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first.map(String.init) == header else { throw GoldenTraceError.badHeader }
        guard lines.count >= 2 else { throw GoldenTraceError.badSettings(line: 2) }
        let settings = try parseSettingsLine(String(lines[1]))
        var frames: [Frame] = []
        for (index, line) in lines.dropFirst(2).enumerated() {
            frames.append(try parseFrameLine(String(line), line: index + 3))
        }
        return GoldenTrace(settings: settings, frames: frames)
    }

    // MARK: - Replay

    /// The pipeline the recorded session ran with.
    public func pipeline() -> InputPipeline {
        var pipeline = InputPipeline()
        settings.apply(to: &pipeline)
        return pipeline
    }

    /// Runs the trace through the pipeline one frame at a time, through an `InputPipelineRunner`,
    /// so the trigger hysteresis and the turbo phase carry from one frame to the next.
    ///
    /// This is the normal path: the emulator takes one sample, runs one frame, and asks again.
    public func replay(through pipeline: InputPipeline) -> [InputSnapshot] {
        var runner = InputPipelineRunner(pipeline: pipeline)
        var out: [InputSnapshot] = []
        out.reserveCapacity(frames.count)
        for frame in frames {
            out.append(runner.process(frame.input))
        }
        return out
    }

    /// Runs the trace through the pipeline in one go, the way a run-ahead host applies a burst
    /// of samples to consecutive emulated frames.
    ///
    /// The difference from `replay(through:)` is where the state lives: the runner owns the
    /// trigger state and counts the frames itself, while here the caller keeps the pipeline and
    /// passes the frame number in. Both have to agree, frame for frame.
    public func runAhead(through pipeline: InputPipeline) -> [InputSnapshot] {
        var pipeline = pipeline
        var out: [InputSnapshot] = []
        out.reserveCapacity(frames.count)
        var frameIndex = 0
        for frame in frames {
            out.append(pipeline.process(frame.input, frame: frameIndex))
            frameIndex &+= 1
        }
        return out
    }

    /// Whether running a trace through the pipeline in one go gives the same output, frame for
    /// frame, as running it frame by frame.
    ///
    /// The trace passed in is the one run in one go; the receiver is the one replayed frame by
    /// frame. Passing the same trace twice is the check the plan asks for: the run-ahead output
    /// must equal the normal output frame for frame. Passing a different trace asks whether the
    /// candidate's run-ahead output matches this trace's normal output.
    public func runAheadEqualsNormal(_ trace: GoldenTrace, pipeline: InputPipeline) -> Bool {
        trace.runAhead(through: pipeline) == replay(through: pipeline)
    }

    /// The snapshots the trace recorded, one per frame.
    public var expectedSnapshots: [InputSnapshot] { frames.map(\.expected) }

    /// Whether replaying the trace through the pipeline reproduces the recorded snapshots.
    public func replaysToRecordedOutput(through pipeline: InputPipeline) -> Bool {
        replay(through: pipeline) == expectedSnapshots
    }

    /// The first frame whose replayed output differs from what was recorded, or `nil` when the
    /// trace replays exactly. A mismatch is reported by frame number, so a broken trace says
    /// which sample went wrong.
    public func firstMismatch(through pipeline: InputPipeline) -> Int? {
        let replayed = replay(through: pipeline)
        for (index, expected) in expectedSnapshots.enumerated() {
            guard index < replayed.count else { return index }
            if replayed[index] != expected { return index }
        }
        return replayed.count == expectedSnapshots.count ? nil : expectedSnapshots.count
    }

    // MARK: - The settings line

    private func settingsLine() -> String {
        let turbo = settings.turbo
            .map { "\($0.key.name):\($0.value.period):\($0.value.phaseOffset)" }
            .sorted()
            .joined(separator: ",")
        return [
            "settings",
            "stick-l=\(settings.leftStick.innerDeadzone)/\(settings.leftStick.outerDeadzone)",
            "stick-r=\(settings.rightStick.innerDeadzone)/\(settings.rightStick.outerDeadzone)",
            "curve-l=\(settings.leftCurve.rawValue)",
            "curve-r=\(settings.rightCurve.rawValue)",
            "trigger-l=\(settings.leftTriggerPressAt)/\(settings.leftTriggerReleaseAt)",
            "trigger-r=\(settings.rightTriggerPressAt)/\(settings.rightTriggerReleaseAt)",
            "stick-as-dpad=\(settings.stickAsDPad ? 1 : 0)",
            "dpad-gate=\(settings.stickAsDPadGate)",
            "turbo=\(turbo)",
        ].joined(separator: " ")
    }

    private static func parseSettingsLine(_ line: String) throws -> PipelineSettings {
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.first == "settings" else { throw GoldenTraceError.badSettings(line: 2) }
        var values: [String: String] = [:]
        for token in tokens.dropFirst() {
            guard let equals = token.firstIndex(of: "=") else { throw GoldenTraceError.badSettings(line: 2) }
            values[String(token[token.startIndex..<equals])] = String(token[token.index(after: equals)...])
        }
        func pair(_ key: String) throws -> (Float, Float) {
            guard let raw = values[key] else { throw GoldenTraceError.badSettings(line: 2) }
            let parts = raw.split(separator: "/")
            guard parts.count == 2, let first = Float(parts[0]), let second = Float(parts[1]) else {
                throw GoldenTraceError.badSettings(line: 2)
            }
            return (first, second)
        }
        func flag(_ key: String) throws -> Bool {
            guard let raw = values[key] else { throw GoldenTraceError.badSettings(line: 2) }
            guard let value = Int(raw) else { throw GoldenTraceError.badSettings(line: 2) }
            return value != 0
        }
        func curve(_ key: String) throws -> ResponseCurve {
            guard let raw = values[key], let value = ResponseCurve(rawValue: raw) else {
                throw GoldenTraceError.badSettings(line: 2)
            }
            return value
        }
        func number(_ key: String) throws -> Float {
            guard let raw = values[key], let value = Float(raw) else { throw GoldenTraceError.badSettings(line: 2) }
            return value
        }

        let leftDeadzone = try pair("stick-l")
        let rightDeadzone = try pair("stick-r")
        let leftTrigger = try pair("trigger-l")
        let rightTrigger = try pair("trigger-r")

        var turbo: [PadButtons: TurboSetting] = [:]
        if let raw = values["turbo"], !raw.isEmpty {
            for entry in raw.split(separator: ",") {
                let parts = entry.split(separator: ":")
                guard parts.count == 3, let period = Int(parts[1]), let phase = Int(parts[2]) else {
                    throw GoldenTraceError.badSettings(line: 2)
                }
                let buttons = PadButtons.buttons(named: String(parts[0]))
                guard !buttons.isEmpty else { throw GoldenTraceError.badSettings(line: 2) }
                turbo[buttons] = TurboSetting(period: period, phaseOffset: phase)
            }
        }

        return PipelineSettings(
            leftStick: StickConfig(innerDeadzone: leftDeadzone.0, outerDeadzone: leftDeadzone.1),
            rightStick: StickConfig(innerDeadzone: rightDeadzone.0, outerDeadzone: rightDeadzone.1),
            leftCurve: try curve("curve-l"),
            rightCurve: try curve("curve-r"),
            leftTriggerPressAt: leftTrigger.0,
            leftTriggerReleaseAt: leftTrigger.1,
            rightTriggerPressAt: rightTrigger.0,
            rightTriggerReleaseAt: rightTrigger.1,
            stickAsDPad: try flag("stick-as-dpad"),
            stickAsDPadGate: try number("dpad-gate"),
            turbo: turbo
        )
    }

    // MARK: - The frame lines

    /// The number of numbers on each side of the arrow.
    private static let numbersPerSide = 13
    /// The tokens in a frame line: the word, the input, the arrow, the output.
    private static var frameTokenCount: Int { 2 + numbersPerSide * 2 }

    private static func frameLine(_ frame: Frame) -> String {
        let input = [
            hex(frame.buttons),
            number(frame.leftStick.x), number(frame.leftStick.y),
            number(frame.rightStick.x), number(frame.rightStick.y),
            number(frame.leftTrigger), number(frame.rightTrigger),
            number(frame.gravity.x), number(frame.gravity.y), number(frame.gravity.z),
            number(frame.rotationRate.x), number(frame.rotationRate.y), number(frame.rotationRate.z),
        ]
        let expected = frame.expected
        let output = [
            hex(expected.buttons.rawValue),
            number(expected.leftStick.x), number(expected.leftStick.y),
            number(expected.rightStick.x), number(expected.rightStick.y),
            number(expected.leftTrigger), number(expected.rightTrigger),
            number(expected.gravity.x), number(expected.gravity.y), number(expected.gravity.z),
            number(expected.rotationRate.x), number(expected.rotationRate.y), number(expected.rotationRate.z),
        ]
        return (["frame"] + input + ["->"] + output).joined(separator: " ")
    }

    private static func parseFrameLine(_ line: String, line number: Int) throws -> Frame {
        let tokens = line.split(separator: " ").map(String.init)
        guard tokens.count == frameTokenCount, tokens.first == "frame" else {
            throw GoldenTraceError.badFrame(line: number)
        }
        let arrow = 1 + numbersPerSide
        guard tokens[arrow] == "->" else { throw GoldenTraceError.badFrame(line: number) }
        let input = try parseSide(Array(tokens[1..<arrow]), line: number)
        let output = try parseSide(Array(tokens[(arrow + 1)...]), line: number)

        var raw = RawControllerState()
        raw.buttons = input.buttons
        raw.leftStick = SIMD2(input.stickX, input.stickY)
        raw.rightStick = SIMD2(input.rightStickX, input.rightStickY)
        raw.leftTrigger = input.leftTrigger
        raw.rightTrigger = input.rightTrigger
        raw.gravity = SIMD3(input.gravityX, input.gravityY, input.gravityZ)
        raw.rotationRate = SIMD3(input.rotationX, input.rotationY, input.rotationZ)

        var expected = InputSnapshot()
        expected.buttons = PadButtons(rawValue: output.buttons)
        expected.leftStick = SIMD2(output.stickX, output.stickY)
        expected.rightStick = SIMD2(output.rightStickX, output.rightStickY)
        expected.leftTrigger = output.leftTrigger
        expected.rightTrigger = output.rightTrigger
        expected.gravity = SIMD3(output.gravityX, output.gravityY, output.gravityZ)
        expected.rotationRate = SIMD3(output.rotationX, output.rotationY, output.rotationZ)

        return Frame(input: raw, expected: expected)
    }

    /// The thirteen numbers of one side of a frame line.
    private struct Side {
        var buttons: UInt64
        var stickX: Float
        var stickY: Float
        var rightStickX: Float
        var rightStickY: Float
        var leftTrigger: Float
        var rightTrigger: Float
        var gravityX: Float
        var gravityY: Float
        var gravityZ: Float
        var rotationX: Float
        var rotationY: Float
        var rotationZ: Float
    }

    private static func parseSide(_ tokens: [String], line: Int) throws -> Side {
        guard tokens.count == numbersPerSide, let buttons = UInt64(tokens[0], radix: 16) else {
            throw GoldenTraceError.badFrame(line: line)
        }
        var values: [Float] = []
        values.reserveCapacity(numbersPerSide - 1)
        for token in tokens.dropFirst() {
            guard let value = Float(token) else { throw GoldenTraceError.badFrame(line: line) }
            values.append(value)
        }
        return Side(
            buttons: buttons,
            stickX: values[0], stickY: values[1],
            rightStickX: values[2], rightStickY: values[3],
            leftTrigger: values[4], rightTrigger: values[5],
            gravityX: values[6], gravityY: values[7], gravityZ: values[8],
            rotationX: values[9], rotationY: values[10], rotationZ: values[11]
        )
    }

    // MARK: - Numbers

    /// A number in the shortest form that reads back as the same value.
    private static func number(_ value: Float) -> String { "\(value)" }

    /// A button mask as sixteen hex digits, so the columns line up in a diff.
    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

/// Why a golden trace could not be read.
public enum GoldenTraceError: Error, Equatable, CustomStringConvertible {
    /// The first line was not the golden trace header.
    case badHeader
    /// The settings line could not be read. The line number is the one in the file.
    case badSettings(line: Int)
    /// A frame line could not be read. The line number is the one in the file.
    case badFrame(line: Int)

    public var description: String {
        switch self {
        case .badHeader:
            return "not a golden trace: the file does not start with \"\(GoldenTrace.header)\""
        case .badSettings(let line):
            return "line \(line): the settings line could not be read"
        case .badFrame(let line):
            return "line \(line): the frame line could not be read"
        }
    }
}

// MARK: - Coding

/// A snapshot in the JSON form: the same thirteen fields as a frame line, plus the button mask.
private struct SnapshotFields: Codable {
    var buttons: UInt64
    var leftStick: [Float]
    var rightStick: [Float]
    var leftTrigger: Float
    var rightTrigger: Float
    var gravity: [Float]
    var rotationRate: [Float]

    init(_ snapshot: InputSnapshot) {
        buttons = snapshot.buttons.rawValue
        leftStick = [snapshot.leftStick.x, snapshot.leftStick.y]
        rightStick = [snapshot.rightStick.x, snapshot.rightStick.y]
        leftTrigger = snapshot.leftTrigger
        rightTrigger = snapshot.rightTrigger
        gravity = [snapshot.gravity.x, snapshot.gravity.y, snapshot.gravity.z]
        rotationRate = [snapshot.rotationRate.x, snapshot.rotationRate.y, snapshot.rotationRate.z]
    }

    var snapshot: InputSnapshot {
        var out = InputSnapshot()
        out.buttons = PadButtons(rawValue: buttons)
        out.leftStick = SIMD2(leftStick[0], leftStick[1])
        out.rightStick = SIMD2(rightStick[0], rightStick[1])
        out.leftTrigger = leftTrigger
        out.rightTrigger = rightTrigger
        out.gravity = SIMD3(gravity[0], gravity[1], gravity[2])
        out.rotationRate = SIMD3(rotationRate[0], rotationRate[1], rotationRate[2])
        return out
    }
}

extension GoldenTrace.Frame {
    private enum CodingKeys: String, CodingKey {
        case buttons, leftStick, rightStick, leftTrigger, rightTrigger
        case gravity, rotationRate, expected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let buttons = try container.decode(UInt64.self, forKey: .buttons)
        let leftStick = try container.decode([Float].self, forKey: .leftStick)
        let rightStick = try container.decode([Float].self, forKey: .rightStick)
        let leftTrigger = try container.decode(Float.self, forKey: .leftTrigger)
        let rightTrigger = try container.decode(Float.self, forKey: .rightTrigger)
        let gravity = try container.decode([Float].self, forKey: .gravity)
        let rotationRate = try container.decode([Float].self, forKey: .rotationRate)
        let expected = try container.decode(SnapshotFields.self, forKey: .expected)

        var raw = RawControllerState()
        raw.buttons = buttons
        raw.leftStick = SIMD2(leftStick[0], leftStick[1])
        raw.rightStick = SIMD2(rightStick[0], rightStick[1])
        raw.leftTrigger = leftTrigger
        raw.rightTrigger = rightTrigger
        raw.gravity = SIMD3(gravity[0], gravity[1], gravity[2])
        raw.rotationRate = SIMD3(rotationRate[0], rotationRate[1], rotationRate[2])
        self.init(input: raw, expected: expected.snapshot)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(buttons, forKey: .buttons)
        try container.encode([leftStick.x, leftStick.y], forKey: .leftStick)
        try container.encode([rightStick.x, rightStick.y], forKey: .rightStick)
        try container.encode(leftTrigger, forKey: .leftTrigger)
        try container.encode(rightTrigger, forKey: .rightTrigger)
        try container.encode([gravity.x, gravity.y, gravity.z], forKey: .gravity)
        try container.encode([rotationRate.x, rotationRate.y, rotationRate.z], forKey: .rotationRate)
        try container.encode(SnapshotFields(expected), forKey: .expected)
    }
}

extension GoldenTrace {
    private enum CodingKeys: String, CodingKey {
        case settings, frames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decode(PipelineSettings.self, forKey: .settings)
        frames = try container.decode([Frame].self, forKey: .frames)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(settings, forKey: .settings)
        try container.encode(frames, forKey: .frames)
    }
}
