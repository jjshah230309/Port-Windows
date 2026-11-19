public enum ControllerFamily: String, Codable, Sendable, CaseIterable {
    case xboxOne, xboxSeries, xboxElite2, xboxAdaptive
    case dualShock4, dualSense, dualSenseEdge
    case generic
}

public enum Transport: String, Codable, Sendable {
    case usb, bluetooth, unknown
}

/// Persistence key for per-controller profiles and player assignment.
/// GameController exposes no serial or VID/PID, so those are filled in only when the opt-in HID layer is on.
public struct ControllerID: Hashable, Codable, Sendable {
    public var family: ControllerFamily
    public var serial: String?
    public var vidPid: UInt32?
    public var transport: Transport

    public init(family: ControllerFamily, serial: String? = nil, vidPid: UInt32? = nil, transport: Transport = .unknown) {
        self.family = family
        self.serial = serial
        self.vidPid = vidPid
        self.transport = transport
    }
}

/// Features a connected pad offers, probed at connect time and never assumed from the model name.
public struct ControllerCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let rumble = ControllerCapabilities(rawValue: 1 << 0)
    public static let triggerRumble = ControllerCapabilities(rawValue: 1 << 1)
    public static let adaptiveTriggers = ControllerCapabilities(rawValue: 1 << 2)
    public static let hdHaptics = ControllerCapabilities(rawValue: 1 << 3)
    public static let touchpad = ControllerCapabilities(rawValue: 1 << 4)
    public static let motion = ControllerCapabilities(rawValue: 1 << 5)
    public static let lightbar = ControllerCapabilities(rawValue: 1 << 6)
    public static let playerLEDs = ControllerCapabilities(rawValue: 1 << 7)
    public static let muteLED = ControllerCapabilities(rawValue: 1 << 8)
    public static let battery = ControllerCapabilities(rawValue: 1 << 9)
    public static let share = ControllerCapabilities(rawValue: 1 << 10)
    public static let paddles = ControllerCapabilities(rawValue: 1 << 11)
    public static let home = ControllerCapabilities(rawValue: 1 << 12)
    public static let audio = ControllerCapabilities(rawValue: 1 << 13)

    public var names: [String] {
        let all: [(ControllerCapabilities, String)] = [
            (.rumble, "rumble"), (.triggerRumble, "trigger rumble"), (.adaptiveTriggers, "adaptive triggers"),
            (.hdHaptics, "HD haptics"), (.touchpad, "touchpad"), (.motion, "motion"), (.lightbar, "lightbar"),
            (.playerLEDs, "player LEDs"), (.muteLED, "mute LED"), (.battery, "battery"), (.share, "share/create"),
            (.paddles, "paddles"), (.home, "home"), (.audio, "audio"),
        ]
        return all.filter { contains($0.0) }.map { $0.1 }
    }
}

public struct TouchPoint: Sendable, Equatable {
    public var isDown: Bool
    /// Normalised 0...1 across the touchpad.
    public var x: Float
    public var y: Float
    public init(isDown: Bool = false, x: Float = 0, y: Float = 0) {
        self.isDown = isDown
        self.x = x
        self.y = y
    }
}

/// Fixed-size, plain-data controller state. Everything the pipeline needs from one pad for one sample.
public struct RawControllerState: Sendable, Equatable {
    public var buttons: UInt64 = 0
    public var leftStick: SIMD2<Float> = .zero
    public var rightStick: SIMD2<Float> = .zero
    public var leftTrigger: Float = 0
    public var rightTrigger: Float = 0
    public var touch0 = TouchPoint()
    public var touch1 = TouchPoint()
    /// g, device frame.
    public var gravity: SIMD3<Float> = .zero
    /// rad/s, device frame.
    public var rotationRate: SIMD3<Float> = .zero
    public var battery: Float = 1
    /// Mach ticks (or any monotonic counter) at sampling time.
    public var timestamp: UInt64 = 0

    public init() {}
}
