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

/// Raw controller state in, logical `InputSnapshot` out.
/// Order: radial deadzone, trigger hysteresis, SOCD. Bindings, turbo and chords layer on later.
public struct InputPipeline: Sendable {
    public var leftStick = StickConfig()
    public var rightStick = StickConfig()
    public var leftTrigger = TriggerHysteresis()
    public var rightTrigger = TriggerHysteresis()

    public init() {}

    public mutating func process(_ raw: RawControllerState) -> InputSnapshot {
        var out = InputSnapshot()
        out.buttons = PadButtons(rawValue: raw.buttons)
        out.leftStick = Deadzone.radial(raw.leftStick, inner: leftStick.innerDeadzone, outer: leftStick.outerDeadzone)
        out.rightStick = Deadzone.radial(raw.rightStick, inner: rightStick.innerDeadzone, outer: rightStick.outerDeadzone)
        out.leftTrigger = raw.leftTrigger
        out.rightTrigger = raw.rightTrigger
        if leftTrigger.update(raw.leftTrigger) { out.buttons.insert(.l2) }
        if rightTrigger.update(raw.rightTrigger) { out.buttons.insert(.r2) }
        out.buttons = SOCD.neutral(out.buttons)
        out.gravity = raw.gravity
        out.rotationRate = raw.rotationRate
        return out
    }
}
