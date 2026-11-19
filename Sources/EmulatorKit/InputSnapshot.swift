/// Logical buttons as seen by an emulated system, after the host pipeline (deadzones, bindings, SOCD).
/// Positional layout: `east` is the right face button, `south` the bottom one, regardless of printed labels.
public struct PadButtons: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let up = PadButtons(rawValue: 1 << 0)
    public static let down = PadButtons(rawValue: 1 << 1)
    public static let left = PadButtons(rawValue: 1 << 2)
    public static let right = PadButtons(rawValue: 1 << 3)
    public static let south = PadButtons(rawValue: 1 << 4)
    public static let east = PadButtons(rawValue: 1 << 5)
    public static let west = PadButtons(rawValue: 1 << 6)
    public static let north = PadButtons(rawValue: 1 << 7)
    public static let l1 = PadButtons(rawValue: 1 << 8)
    public static let r1 = PadButtons(rawValue: 1 << 9)
    public static let l2 = PadButtons(rawValue: 1 << 10)
    public static let r2 = PadButtons(rawValue: 1 << 11)
    public static let l3 = PadButtons(rawValue: 1 << 12)
    public static let r3 = PadButtons(rawValue: 1 << 13)
    public static let start = PadButtons(rawValue: 1 << 14)
    public static let select = PadButtons(rawValue: 1 << 15)
    public static let home = PadButtons(rawValue: 1 << 16)
    public static let share = PadButtons(rawValue: 1 << 17)
    public static let touchpadClick = PadButtons(rawValue: 1 << 18)
}

/// What a core sees when it reads a pad. Floats are already deadzoned and in -1...1 (sticks) / 0...1 (triggers).
public struct InputSnapshot: Sendable, Equatable {
    public var buttons: PadButtons = []
    public var leftStick: SIMD2<Float> = .zero
    public var rightStick: SIMD2<Float> = .zero
    public var leftTrigger: Float = 0
    public var rightTrigger: Float = 0
    /// Gravity in units of g, relative to the neutral pose.
    public var gravity: SIMD3<Float> = .zero
    /// Angular rate in rad/s, bias removed.
    public var rotationRate: SIMD3<Float> = .zero

    public init() {}
}

/// Where a core reads its pads. The core calls `snapshot(port:)` on the first guest pad read of each frame.
public protocol InputSource: AnyObject {
    func snapshot(port: Int) -> InputSnapshot
}

/// Where a core sends rumble and light output. Written only on committed frames.
public protocol OutputSink: AnyObject {
    func setRumble(port: Int, low: Float, high: Float)
}
