import EmulatorKit

/// User settings for the input pipeline: deadzones, response curves, trigger thresholds, the
/// stick-as-d-pad switch and the turbo buttons.
///
/// The defaults are the pipeline's own defaults, so a settings file that has never been written
/// leaves the input alone. The type is `Codable` so the settings survive a restart.
///
/// The module stays free of Foundation, so the writing of the file is left to the layer above:
/// a caller encodes these with a `JSONEncoder` that sorts its keys.
public struct PipelineSettings: Codable, Equatable, Sendable {
    public var leftStick: StickConfig
    public var rightStick: StickConfig
    public var leftCurve: ResponseCurve
    public var rightCurve: ResponseCurve
    /// The trigger travel at which a trigger counts as pressed.
    public var leftTriggerPressAt: Float
    /// The trigger travel at which a trigger counts as released again.
    public var leftTriggerReleaseAt: Float
    public var rightTriggerPressAt: Float
    public var rightTriggerReleaseAt: Float
    /// When on, the left stick also drives the d-pad.
    public var stickAsDPad: Bool
    /// The magnitude a stick must reach before it counts as a d-pad push.
    public var stickAsDPadGate: Float
    /// Turbo settings per button. A button with no entry is held, not repeated.
    public var turbo: [PadButtons: TurboSetting]

    public init(
        leftStick: StickConfig = StickConfig(),
        rightStick: StickConfig = StickConfig(),
        leftCurve: ResponseCurve = .linear,
        rightCurve: ResponseCurve = .linear,
        leftTriggerPressAt: Float = 0.35,
        leftTriggerReleaseAt: Float = 0.25,
        rightTriggerPressAt: Float = 0.35,
        rightTriggerReleaseAt: Float = 0.25,
        stickAsDPad: Bool = false,
        stickAsDPadGate: Float = 0.5,
        turbo: [PadButtons: TurboSetting] = [:]
    ) {
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftCurve = leftCurve
        self.rightCurve = rightCurve
        self.leftTriggerPressAt = leftTriggerPressAt
        self.leftTriggerReleaseAt = leftTriggerReleaseAt
        self.rightTriggerPressAt = rightTriggerPressAt
        self.rightTriggerReleaseAt = rightTriggerReleaseAt
        self.stickAsDPad = stickAsDPad
        self.stickAsDPadGate = stickAsDPadGate
        self.turbo = turbo
    }

    // MARK: - Applying

    /// Pushes the settings into a live pipeline.
    ///
    /// The turbo dictionary is replaced wholesale: the settings are the whole picture, so a
    /// button the user has taken off turbo is simply held again.
    public func apply(to pipeline: inout InputPipeline) {
        pipeline.leftStick = leftStick
        pipeline.rightStick = rightStick
        pipeline.leftCurve = leftCurve
        pipeline.rightCurve = rightCurve
        pipeline.stickAsDPad = stickAsDPad
        pipeline.stickAsDPadGate = stickAsDPadGate
        pipeline.turbo = turbo
        pipeline.leftTrigger = trigger(pressAt: leftTriggerPressAt, releaseAt: leftTriggerReleaseAt, keeping: pipeline.leftTrigger)
        pipeline.rightTrigger = trigger(pressAt: rightTriggerPressAt, releaseAt: rightTriggerReleaseAt, keeping: pipeline.rightTrigger)
    }

    /// Pushes the settings into a pipeline held by a runner.
    ///
    /// The frame counter is kept, because turbo counts frames and a settings change should not
    /// restart the rhythm.
    public func apply(to runner: inout InputPipelineRunner) {
        var pipeline = runner.pipeline
        apply(to: &pipeline)
        runner.update(pipeline: pipeline)
    }

    /// The trigger to use for the new thresholds. A trigger whose thresholds have not moved keeps
    /// its pressed state, so a button the user is holding is not dropped by an unrelated change;
    /// one whose thresholds have moved is re-armed, because the old pressed state was measured
    /// against other numbers.
    private func trigger(pressAt: Float, releaseAt: Float, keeping old: TriggerHysteresis) -> TriggerHysteresis {
        if old.pressAt == pressAt && old.releaseAt == releaseAt { return old }
        return TriggerHysteresis(pressAt: pressAt, releaseAt: releaseAt)
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case leftStick, rightStick, leftCurve, rightCurve
        case leftTriggerPressAt, leftTriggerReleaseAt
        case rightTriggerPressAt, rightTriggerReleaseAt
        case stickAsDPad, stickAsDPadGate, turbo
    }

    private enum StickCodingKeys: String, CodingKey {
        case innerDeadzone, outerDeadzone
    }

    /// One turbo button as it appears in the settings file. The buttons are written out by name
    /// rather than as a raw bit mask, so a settings file stays readable and a bit that moves
    /// does not silently repoint a turbo button.
    private struct TurboEntry: Codable {
        var button: String
        var period: Int
        var phaseOffset: Int

        init(button: String, period: Int, phaseOffset: Int) {
            self.button = button
            self.period = period
            self.phaseOffset = phaseOffset
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            button = (try? container.decodeIfPresent(String.self, forKey: .button)) ?? ""
            period = (try? container.decodeIfPresent(Int.self, forKey: .period)) ?? 0
            phaseOffset = (try? container.decodeIfPresent(Int.self, forKey: .phaseOffset)) ?? 0
        }

        private enum CodingKeys: String, CodingKey {
            case button, period, phaseOffset
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leftStick = Self.decodeStick(from: container, forKey: .leftStick)
        rightStick = Self.decodeStick(from: container, forKey: .rightStick)
        leftCurve = (try? container.decodeIfPresent(ResponseCurve.self, forKey: .leftCurve)) ?? .linear
        rightCurve = (try? container.decodeIfPresent(ResponseCurve.self, forKey: .rightCurve)) ?? .linear
        leftTriggerPressAt = (try? container.decodeIfPresent(Float.self, forKey: .leftTriggerPressAt)) ?? 0.35
        leftTriggerReleaseAt = (try? container.decodeIfPresent(Float.self, forKey: .leftTriggerReleaseAt)) ?? 0.25
        rightTriggerPressAt = (try? container.decodeIfPresent(Float.self, forKey: .rightTriggerPressAt)) ?? 0.35
        rightTriggerReleaseAt = (try? container.decodeIfPresent(Float.self, forKey: .rightTriggerReleaseAt)) ?? 0.25
        stickAsDPad = (try? container.decodeIfPresent(Bool.self, forKey: .stickAsDPad)) ?? false
        stickAsDPadGate = (try? container.decodeIfPresent(Float.self, forKey: .stickAsDPadGate)) ?? 0.5

        var decodedTurbo: [PadButtons: TurboSetting] = [:]
        let entries = (try? container.decodeIfPresent([TurboEntry].self, forKey: .turbo)) ?? []
        for entry in entries {
            let buttons = PadButtons.buttons(named: entry.button)
            // A name this build does not know is skipped, so a settings file written by a newer
            // build still loads the rest of its buttons.
            guard !buttons.isEmpty else { continue }
            decodedTurbo[buttons] = TurboSetting(period: entry.period, phaseOffset: entry.phaseOffset)
        }
        turbo = decodedTurbo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leftStick, forKey: .leftStick)
        try container.encode(rightStick, forKey: .rightStick)
        try container.encode(leftCurve, forKey: .leftCurve)
        try container.encode(rightCurve, forKey: .rightCurve)
        try container.encode(leftTriggerPressAt, forKey: .leftTriggerPressAt)
        try container.encode(leftTriggerReleaseAt, forKey: .leftTriggerReleaseAt)
        try container.encode(rightTriggerPressAt, forKey: .rightTriggerPressAt)
        try container.encode(rightTriggerReleaseAt, forKey: .rightTriggerReleaseAt)
        try container.encode(stickAsDPad, forKey: .stickAsDPad)
        try container.encode(stickAsDPadGate, forKey: .stickAsDPadGate)
        try container.encode(turboEntries(), forKey: .turbo)
    }

    /// The turbo buttons in a fixed order, so the same settings always encode to the same bytes.
    private func turboEntries() -> [TurboEntry] {
        turbo
            .map { TurboEntry(button: $0.key.name, period: $0.value.period, phaseOffset: $0.value.phaseOffset) }
            .sorted { $0.button < $1.button }
    }

    /// A stick configuration, with any missing part of it left at the default.
    private static func decodeStick(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> StickConfig {
        guard let nested = try? container.nestedContainer(keyedBy: StickCodingKeys.self, forKey: key) else {
            return StickConfig()
        }
        var config = StickConfig()
        if let inner = try? nested.decodeIfPresent(Float.self, forKey: .innerDeadzone) {
            config.innerDeadzone = inner
        }
        if let outer = try? nested.decodeIfPresent(Float.self, forKey: .outerDeadzone) {
            config.outerDeadzone = outer
        }
        return config
    }
}

public extension PadButtons {
    /// The name this button is written under in the settings file.
    ///
    /// These names are part of the file format, so they do not change: renaming one makes every
    /// settings file that used it lose that button. A set of several buttons is written as the
    /// names joined by a plus sign, in the order of the table below.
    var name: String {
        if let single = PadButtonName.table.first(where: { $0.0 == self }) { return single.1 }
        return PadButtonName.table.filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }

    /// The buttons a settings-file name stands for. A name this build does not know is dropped.
    static func buttons(named name: String) -> PadButtons {
        var out: PadButtons = []
        for part in name.split(separator: "+") {
            if let match = PadButtonName.table.first(where: { $0.1 == part }) { out.insert(match.0) }
        }
        return out
    }
}

/// The button names used in the settings file, in the pipeline's own order.
private enum PadButtonName {
    static let table: [(PadButtons, String)] = [
        (.up, "up"), (.down, "down"), (.left, "left"), (.right, "right"),
        (.south, "south"), (.east, "east"), (.west, "west"), (.north, "north"),
        (.l1, "l1"), (.r1, "r1"), (.l2, "l2"), (.r2, "r2"),
        (.l3, "l3"), (.r3, "r3"), (.start, "start"), (.select, "select"),
        (.home, "home"), (.share, "share"), (.touchpadClick, "touchpadClick"),
    ]
}
