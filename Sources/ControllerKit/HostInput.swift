import AppKit
import ControllerModel
import EmulatorKit
import GameController
import LibraryKit
import Synchronization

/// Keyboard state, written by the view on the main thread and read by the emulation thread.
public final class KeyboardInput: @unchecked Sendable {
    private struct State {
        var held = Set<UInt16>()
        var bindings = KeyboardBindings()
    }

    private let state = Mutex(State())

    public init() {}

    public func handle(keyCode: UInt16, down: Bool) {
        state.withLock { s in
            if down { s.held.insert(keyCode) } else { s.held.remove(keyCode) }
        }
    }

    public var heldKeys: Set<UInt16> { state.withLock { $0.held } }

    public var bindings: KeyboardBindings {
        get { state.withLock { $0.bindings } }
        set { state.withLock { $0.bindings = newValue } }
    }

    /// Game buttons for the keys currently held, through the current bindings.
    public func gameButtons() -> PadButtons {
        state.withLock { s in
            var out: PadButtons = []
            for key in s.held { if let b = s.bindings.button(forKeyCode: key) { out.formUnion(b) } }
            return out
        }
    }
}

/// Reads the first connected game controller. Element names are Apple's (the same on Xbox, DualShock 4 and DualSense).
/// Positional layout: the right face button is `east`, the bottom one `south` ("Button B" and "Button A").
public final class GamepadInput: @unchecked Sendable {
    private let bindingsState = Mutex(GamepadBindings())

    public init() {}

    public var bindings: GamepadBindings {
        get { bindingsState.withLock { $0 } }
        set { bindingsState.withLock { $0 = newValue } }
    }

    public var isConnected: Bool { GCController.controllers().first?.extendedGamepad != nil }

    /// Names of the buttons, triggers and d-pad directions currently pressed.
    public func heldElements() -> Set<String> {
        guard let pad = GCController.controllers().first?.extendedGamepad else { return [] }
        var held = Set<String>()
        func check(_ name: String, _ button: GCControllerButtonInput?) {
            if button?.isPressed == true { held.insert(name) }
        }
        check("Button A", pad.buttonA); check("Button B", pad.buttonB)
        check("Button X", pad.buttonX); check("Button Y", pad.buttonY)
        check("Left Shoulder", pad.leftShoulder); check("Right Shoulder", pad.rightShoulder)
        check("Left Trigger", pad.leftTrigger); check("Right Trigger", pad.rightTrigger)
        check("Button Menu", pad.buttonMenu); check("Button Options", pad.buttonOptions)
        check("Left Thumbstick Button", pad.leftThumbstickButton)
        check("Right Thumbstick Button", pad.rightThumbstickButton)
        check("Direction Pad Up", pad.dpad.up); check("Direction Pad Down", pad.dpad.down)
        check("Direction Pad Left", pad.dpad.left); check("Direction Pad Right", pad.dpad.right)
        return held
    }

    /// Left stick position, -1...1, y up.
    public var leftStick: (x: Float, y: Float) {
        guard let s = GCController.controllers().first?.extendedGamepad?.leftThumbstick else { return (0, 0) }
        return (s.xAxis.value, s.yAxis.value)
    }

    public var rightStick: (x: Float, y: Float) {
        guard let s = GCController.controllers().first?.extendedGamepad?.rightThumbstick else { return (0, 0) }
        return (s.xAxis.value, s.yAxis.value)
    }

    /// The left stick as a vector, for the input pipeline.
    public var leftStickVector: SIMD2<Float> {
        let s = leftStick
        return SIMD2(s.x, s.y)
    }

    /// The right stick as a vector, for the input pipeline.
    public var rightStickVector: SIMD2<Float> {
        let s = rightStick
        return SIMD2(s.x, s.y)
    }

    /// Left trigger travel, 0...1.
    public var leftTriggerValue: Float {
        GCController.controllers().first?.extendedGamepad?.leftTrigger.value ?? 0
    }

    /// Right trigger travel, 0...1.
    public var rightTriggerValue: Float {
        GCController.controllers().first?.extendedGamepad?.rightTrigger.value ?? 0
    }

    /// Game buttons: d-pad and left stick as directions, plus bound buttons not used by a hotkey chord.
    public func gameButtons(suppressing suppressed: Set<String>) -> PadButtons {
        let held = heldElements()
        var out: PadButtons = []
        if held.contains("Direction Pad Up") { out.insert(.up) }
        if held.contains("Direction Pad Down") { out.insert(.down) }
        if held.contains("Direction Pad Left") { out.insert(.left) }
        if held.contains("Direction Pad Right") { out.insert(.right) }
        let stick = leftStick
        if stick.y > 0.5 { out.insert(.up) }
        if stick.y < -0.5 { out.insert(.down) }
        if stick.x < -0.5 { out.insert(.left) }
        if stick.x > 0.5 { out.insert(.right) }
        let map = bindings.map
        for name in held where !suppressed.contains(name) { if let b = map[name] { out.formUnion(b) } }
        return out
    }
}

/// Merges keyboard and controller into the snapshot a core reads, and evaluates hotkeys.
public final class HostInput: InputSource, @unchecked Sendable {
    public let keyboard = KeyboardInput()
    public let gamepad = GamepadInput()
    private let hotkeyState = Mutex(HotkeyEngine())
    private let pipelineState = Mutex(InputPipeline())
    /// The emulated frame the turbo counters run on. The pipeline is a value type, so the frame
    /// number has to travel with it for turbo to repeat deterministically.
    private let frame = Atomic<UInt64>(0)

    public init() {}

    public var hotkeyEngine: HotkeyEngine {
        get { hotkeyState.withLock { $0 } }
        set { hotkeyState.withLock { $0 = newValue } }
    }

    /// The live input pipeline. Its settings drive the sticks, the triggers and the turbo buttons.
    public var pipeline: InputPipeline {
        get { pipelineState.withLock { $0 } }
        set { pipelineState.withLock { $0 = newValue } }
    }

    /// Advances the emulated-frame counter that turbo counts.
    public func advanceFrame() {
        frame.wrappingAdd(1, ordering: .relaxed)
    }

    private func evaluate() -> HotkeyEngine.Evaluation {
        hotkeyEngine.evaluate(heldKeys: keyboard.heldKeys, heldElements: gamepad.heldElements())
    }

    /// Hotkey actions currently held (keyboard keys and controller chords).
    public func heldHotkeys() -> Set<HotkeyAction> { evaluate().actions }

    public func snapshot(port: Int) -> InputSnapshot {
        let e = evaluate()
        // The keyboard has no analogue axes, so it goes through the same pipeline to share the
        // SOCD and turbo rules with the pad.
        let keyboardButtons = keyboard.gameButtons()
        let padButtons = gamepad.gameButtons(suppressing: e.suppressedElements)
        var raw = RawControllerState()
        raw.buttons = keyboardButtons.union(padButtons).rawValue
        raw.leftStick = gamepad.leftStickVector
        raw.rightStick = gamepad.rightStickVector
        raw.leftTrigger = gamepad.leftTriggerValue
        raw.rightTrigger = gamepad.rightTriggerValue
        var p = pipeline
        return p.process(raw, frame: Int(frame.load(ordering: .relaxed)))
    }
}

/// Drives controller rumble from the core's rumble output. Haptics calls happen on a private queue so a slow call
/// can never stall the emulation thread.
public final class HostOutput: OutputSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "attic.rumble")
    private var engine: CHHapticEngineBox?

    public init() {}

    public func setRumble(port: Int, low: Float, high: Float) {
        let level = max(low, high)
        queue.async { [self] in
            if engine == nil, let controller = GCController.controllers().first { engine = CHHapticEngineBox(controller: controller) }
            engine?.set(intensity: level)
        }
    }
}
