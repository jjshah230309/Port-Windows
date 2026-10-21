import EmulatorKit

public struct StickConfig: Codable, Sendable, Equatable {
    /// Inside this radius the stick reads zero.
    public var innerDeadzone: Float = 0.12
    /// At or beyond this radius the stick reads full scale.
    public var outerDeadzone: Float = 0.97
    public init(innerDeadzone: Float = 0.12, outerDeadzone: Float = 0.97) {
        self.innerDeadzone = innerDeadzone
        self.outerDeadzone = outerDeadzone
    }
}

public enum Deadzone {
    /// Scaled radial deadzone: v' = v/|v| * min((|v| - inner) / (outer - inner), 1) for |v| > inner, else 0.
    public static func radial(_ v: SIMD2<Float>, inner: Float, outer: Float) -> SIMD2<Float> {
        let magnitude = (v * v).sum().squareRoot()
        guard magnitude > inner, outer > inner else { return .zero }
        let scaled = min((magnitude - inner) / (outer - inner), 1)
        return v / magnitude * scaled
    }
}

/// How the stick's travel is shaped after the deadzone. A game sees 0...1 of travel; how fast that
/// travel grows is a preference, so the curve is user-configurable.
public enum ResponseCurve: String, Codable, Sendable, CaseIterable, Equatable {
    /// Linear travel: the default, so behaviour does not change unless asked.
    case linear
    /// Gentle start, then full speed sooner. Good for fine positioning.
    case eased
    /// Slow start, fast end. Good for precise aiming near the centre.
    case aggressive

    /// Maps a 0...1 magnitude to a 0...1 magnitude.
    public func apply(_ x: Float) -> Float {
        switch self {
        case .linear: return x
        case .eased: return x * x * (3 - 2 * x)          // smoothstep
        case .aggressive: return x * x * x
        }
    }

    public var label: String {
        switch self {
        case .linear: return "Linear"
        case .eased: return "Eased"
        case .aggressive: return "Aggressive"
        }
    }
}

/// Schmitt trigger for analog triggers used as buttons.
public struct TriggerHysteresis: Sendable, Equatable {
    public var pressAt: Float
    public var releaseAt: Float
    public private(set) var isPressed = false

    public init(pressAt: Float = 0.35, releaseAt: Float = 0.25) {
        self.pressAt = pressAt
        self.releaseAt = releaseAt
    }

    @discardableResult
    public mutating func update(_ value: Float) -> Bool {
        if isPressed {
            if value <= releaseAt { isPressed = false }
        } else if value >= pressAt {
            isPressed = true
        }
        return isPressed
    }
}

public enum StickToDPad {
    /// Eight-way direction from a stick, gated on magnitude. Sector boundaries sit at 22.5 degrees + k * 45.
    public static func buttons(for v: SIMD2<Float>, gate: Float = 0.5) -> PadButtons {
        let magnitude = (v * v).sum().squareRoot()
        guard magnitude >= gate else { return [] }
        // y is up-positive. Compare against tan(22.5 deg) = 0.41421356 to pick octants without trig.
        let t: Float = 0.414_213_56
        let ax = abs(v.x), ay = abs(v.y)
        var out: PadButtons = []
        if ay > ax * t { out.insert(v.y > 0 ? .up : .down) }
        if ax > ay * t { out.insert(v.x > 0 ? .right : .left) }
        return out
    }
}

public enum SOCD {
    /// Opposing directions cancel (neutral). Real handheld pads never press both at once.
    public static func neutral(_ b: PadButtons) -> PadButtons {
        var out = b
        if out.contains(.up) && out.contains(.down) { out.subtract([.up, .down]) }
        if out.contains(.left) && out.contains(.right) { out.subtract([.left, .right]) }
        return out
    }
}

/// A button that repeats while it is held: on for `period` emulated frames, off for `period` again.
public struct TurboSetting: Codable, Sendable, Equatable {
    /// Frames on, then frames off. A period of 0 means the button is simply held.
    public var period: Int
    /// True when the button starts in its "on" phase, so two buttons on the same period do not fire in lockstep.
    public var phaseOffset: Int

    public init(period: Int = 0, phaseOffset: Int = 0) {
        self.period = period
        self.phaseOffset = phaseOffset
    }

    /// Whether the button is pressed on the given emulated frame.
    public func isPressed(onFrame frame: Int) -> Bool {
        guard period > 0 else { return true }
        let phase = (frame + phaseOffset) % (period * 2)
        return phase < period
    }
}

/// Raw controller state in, logical `InputSnapshot` out.
/// Order: radial deadzone, response curve, trigger hysteresis, SOCD, then the emulated-frame stages
/// (stick as d-pad, turbo) which need the frame counter to stay deterministic.
public struct InputPipeline: Sendable {
    public var leftStick = StickConfig()
    public var rightStick = StickConfig()
    public var leftTrigger = TriggerHysteresis()
    public var rightTrigger = TriggerHysteresis()
    public var leftCurve: ResponseCurve = .linear
    public var rightCurve: ResponseCurve = .linear
    /// When on, the left stick also drives the d-pad.
    public var stickAsDPad = false
    /// The magnitude a stick must reach before it counts as a d-pad push.
    public var stickAsDPadGate: Float = 0.5
    /// Turbo settings per button. A button with no entry is held, not repeated.
    public var turbo: [PadButtons: TurboSetting] = [:]

    public init() {}

    public mutating func process(_ raw: RawControllerState, frame: Int = 0) -> InputSnapshot {
        var out = InputSnapshot()
        out.buttons = PadButtons(rawValue: raw.buttons)
        out.leftStick = curve(leftCurve, apply: Deadzone.radial(raw.leftStick, inner: leftStick.innerDeadzone, outer: leftStick.outerDeadzone))
        out.rightStick = curve(rightCurve, apply: Deadzone.radial(raw.rightStick, inner: rightStick.innerDeadzone, outer: rightStick.outerDeadzone))
        out.leftTrigger = raw.leftTrigger
        out.rightTrigger = raw.rightTrigger
        if leftTrigger.update(raw.leftTrigger) { out.buttons.insert(.l2) }
        if rightTrigger.update(raw.rightTrigger) { out.buttons.insert(.r2) }
        out.buttons = SOCD.neutral(out.buttons)
        if stickAsDPad {
            out.buttons.formUnion(StickToDPad.buttons(for: out.leftStick, gate: stickAsDPadGate))
        }
        out.buttons = applyTurbo(out.buttons, frame: frame)
        out.gravity = raw.gravity
        out.rotationRate = raw.rotationRate
        return out
    }

    /// Reshapes the stick's travel without changing its direction.
    private func curve(_ c: ResponseCurve, apply v: SIMD2<Float>) -> SIMD2<Float> {
        guard c != .linear else { return v }
        let magnitude = (v * v).sum().squareRoot()
        guard magnitude > 0 else { return v }
        return v / magnitude * c.apply(magnitude)
    }

    /// A turbo button is only pressed on the frames its setting says so; everything else is held.
    private func applyTurbo(_ buttons: PadButtons, frame: Int) -> PadButtons {
        guard !turbo.isEmpty else { return buttons }
        var out: PadButtons = []
        for bit in PadButtons.allButtons where buttons.contains(bit) {
            if let setting = turbo[bit] {
                if setting.isPressed(onFrame: frame) { out.insert(bit) }
            } else {
                out.insert(bit)
            }
        }
        return out
    }
}

public extension PadButtons {
    /// Every single button, so a set can be walked one bit at a time.
    static var allButtons: [PadButtons] {
        [.up, .down, .left, .right, .south, .east, .west, .north,
         .l1, .r1, .l2, .r2, .l3, .r3, .start, .select, .home, .share, .touchpadClick]
    }
}
