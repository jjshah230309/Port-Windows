import AppKit
import ControllerModel
import EmulatorKit
import GameController
import Synchronization

/// Keyboard state, written by the view on the main thread and read by the emulation thread.
public final class KeyboardInput: @unchecked Sendable {
    private let pressed = Mutex<PadButtons>([])

    /// Hardware key codes (layout independent): arrows, X = A, Z = B, Return = Start, Delete / Right Shift = Select.
    private static let map: [UInt16: PadButtons] = [
        126: .up, 125: .down, 123: .left, 124: .right,
        7: .east, 6: .south, 36: .start, 51: .select, 60: .select, 56: .select,
    ]

    public init() {}

    public func handle(keyCode: UInt16, down: Bool) {
        guard let button = Self.map[keyCode] else { return }
        pressed.withLock { state in
            if down { state.insert(button) } else { state.remove(button) }
        }
    }

    public var buttons: PadButtons { pressed.withLock { $0 } }
}

/// Reads the first connected game controller. Positional layout: the right face button is `east`, the bottom one
/// `south`, on Xbox and PlayStation pads alike (Apple's `buttonB` is the right one, `buttonA` the bottom one).
public final class GamepadInput: @unchecked Sendable {
    public init() {}

    public func buttons() -> PadButtons {
        guard let pad = GCController.controllers().first?.extendedGamepad else { return [] }
        var b: PadButtons = []
        let stick = pad.leftThumbstick
        if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { b.insert(.up) }
        if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { b.insert(.down) }
        if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { b.insert(.left) }
        if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { b.insert(.right) }
        if pad.buttonB.isPressed { b.insert(.east) }
        if pad.buttonA.isPressed { b.insert(.south) }
        if pad.buttonY.isPressed { b.insert(.north) }
        if pad.buttonX.isPressed { b.insert(.west) }
        if pad.leftShoulder.isPressed { b.insert(.l1) }
        if pad.rightShoulder.isPressed { b.insert(.r1) }
        if pad.buttonMenu.isPressed { b.insert(.start) }
        if pad.buttonOptions?.isPressed == true { b.insert(.select) }
        return b
    }
}

/// Merges keyboard and controller into the snapshot a core reads.
public final class HostInput: InputSource, @unchecked Sendable {
    public let keyboard = KeyboardInput()
    public let gamepad = GamepadInput()

    public init() {}

    public func snapshot(port: Int) -> InputSnapshot {
        var s = InputSnapshot()
        s.buttons = keyboard.buttons.union(gamepad.buttons())
        return s
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
