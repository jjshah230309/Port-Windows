import EmulatorKit

/// Keyboard layout: hardware key code -> logical button. Key codes are layout independent (a key is the same
/// physical key on a French or a US keyboard).
public struct KeyboardBindings: Equatable, Sendable {
    public private(set) var map: [UInt16: PadButtons]

    /// Arrows, X = A, Z = B, Return = Start, Delete / Shift = Select.
    public static let defaults: [UInt16: PadButtons] = [
        126: .up, 125: .down, 123: .left, 124: .right,
        7: .east, 6: .south, 36: .start, 51: .select, 60: .select, 56: .select,
    ]

    public init(overrides: [String: UInt64] = [:]) {
        var m = Self.defaults
        for (key, raw) in overrides {
            guard let code = UInt16(key) else { continue }
            if raw == 0 { m[code] = nil } else { m[code] = PadButtons(rawValue: raw) }
        }
        map = m
    }

    public func button(forKeyCode code: UInt16) -> PadButtons? { map[code] }

    /// Moves `button` to `keyCode`, removing it from any key it was on (a button has one key; a key one button).
    public mutating func rebind(_ button: PadButtons, toKeyCode code: UInt16) {
        for (k, v) in map where v == button { map[k] = nil }
        map[code] = button
    }

    /// Only the differences from the defaults, for saving.
    public var overrides: [String: UInt64] {
        var out: [String: UInt64] = [:]
        for (k, v) in map where Self.defaults[k] != v { out[String(k)] = v.rawValue }
        for k in Self.defaults.keys where map[k] == nil { out[String(k)] = 0 }
        return out
    }
}

/// Controller layout: Apple element name -> logical button, for the face buttons, shoulders and menu buttons.
/// The d-pad and left stick always mean directions. Names are the same on Xbox, DualShock 4 and DualSense pads.
public struct GamepadBindings: Equatable, Sendable {
    public private(set) var map: [String: PadButtons]

    public static let defaults: [String: PadButtons] = [
        "Button B": .east, "Button A": .south, "Button Y": .north, "Button X": .west,
        "Left Shoulder": .l1, "Right Shoulder": .r1,
        "Button Menu": .start, "Button Options": .select,
    ]

    public init(overrides: [String: UInt64] = [:]) {
        var m = Self.defaults
        for (name, raw) in overrides { m[name] = raw == 0 ? nil : PadButtons(rawValue: raw) }
        map = m
    }

    public mutating func rebind(_ button: PadButtons, toElement name: String) {
        for (k, v) in map where v == button { map[k] = nil }
        map[name] = button
    }

    public var overrides: [String: UInt64] {
        var out: [String: UInt64] = [:]
        for (k, v) in map where Self.defaults[k] != v { out[k] = v.rawValue }
        for k in Self.defaults.keys where map[k] == nil { out[k] = 0 }
        return out
    }
}

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case pause, fastForward, rewind, saveState, loadState, nextSlot, previousSlot, reset

    /// Held actions repeat while the key is down; the others fire once per press.
    public var isHeld: Bool { self == .fastForward || self == .rewind }
}

/// Maps keys and controller chords to emulator actions. A chord is "hold the modifier button, press another":
/// by default Options (Share on a DualShock 4, Create on a DualSense, View on an Xbox pad) is the modifier.
public struct HotkeyEngine: Equatable, Sendable {
    public var keyboard: [UInt16: HotkeyAction]
    public var chordModifier: String
    public var chords: [String: HotkeyAction]

    /// F5 save, F8 load, [ and ] change slot, P pause, Tab fast-forward, R rewind.
    public static let defaultKeyboard: [UInt16: HotkeyAction] = [
        96: .saveState, 100: .loadState, 33: .previousSlot, 30: .nextSlot,
        35: .pause, 48: .fastForward, 15: .rewind,
    ]

    public static let defaultChords: [String: HotkeyAction] = [
        "Right Shoulder": .saveState, "Left Shoulder": .loadState,
        "Right Trigger": .fastForward, "Left Trigger": .rewind,
        "Button Menu": .pause, "Direction Pad Right": .nextSlot, "Direction Pad Left": .previousSlot,
    ]

    public init(keyboard: [UInt16: HotkeyAction] = Self.defaultKeyboard,
                chordModifier: String = "Button Options",
                chords: [String: HotkeyAction] = Self.defaultChords) {
        self.keyboard = keyboard
        self.chordModifier = chordModifier
        self.chords = chords
    }

    public struct Evaluation: Equatable {
        /// Actions currently held down.
        public var actions: Set<HotkeyAction>
        /// Controller elements the game must not see because a chord is using them.
        public var suppressedElements: Set<String>
    }

    public func evaluate(heldKeys: Set<UInt16>, heldElements: Set<String>) -> Evaluation {
        var actions = Set<HotkeyAction>()
        for key in heldKeys { if let a = keyboard[key] { actions.insert(a) } }
        var suppressed = Set<String>()
        if heldElements.contains(chordModifier) {
            for (element, action) in chords where heldElements.contains(element) {
                actions.insert(action)
                suppressed.insert(element)
                suppressed.insert(chordModifier)
            }
        }
        return Evaluation(actions: actions, suppressedElements: suppressed)
    }
}

/// Turns "currently held actions" into one-shot presses for non-held actions and level changes for held ones.
public struct HotkeyEdges {
    private var previous = Set<HotkeyAction>()

    public init() {}

    public struct Result: Equatable {
        public var pressed: Set<HotkeyAction>       // went down this time
        public var held: Set<HotkeyAction>          // currently down (all)
    }

    public mutating func update(_ current: Set<HotkeyAction>) -> Result {
        let pressed = current.subtracting(previous)
        previous = current
        return Result(pressed: pressed, held: current)
    }
}
