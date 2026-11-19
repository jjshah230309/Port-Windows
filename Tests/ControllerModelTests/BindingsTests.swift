import Testing
import EmulatorKit
@testable import ControllerModel

@Suite struct BindingsTests {
    @Test func keyboardDefaultsAndOverrides() {
        var kb = KeyboardBindings()
        #expect(kb.button(forKeyCode: 7) == .east)
        #expect(kb.overrides.isEmpty)
        kb.rebind(.east, toKeyCode: 0)          // A key becomes the A button
        #expect(kb.button(forKeyCode: 0) == .east)
        #expect(kb.button(forKeyCode: 7) == nil)    // X no longer maps to it
        let restored = KeyboardBindings(overrides: kb.overrides)
        #expect(restored == kb)
    }

    @Test func gamepadOverridesRoundTrip() {
        var pad = GamepadBindings()
        pad.rebind(.east, toElement: "Button A")      // swap to the bottom button
        #expect(pad.map["Button A"] == .east)
        #expect(pad.map["Button B"] == nil)
        #expect(GamepadBindings(overrides: pad.overrides) == pad)
    }

    @Test func chordsSuppressTheGameButtons() {
        let engine = HotkeyEngine()
        let e = engine.evaluate(heldKeys: [], heldElements: ["Button Options", "Right Shoulder", "Button A"])
        #expect(e.actions == [.saveState])
        #expect(e.suppressedElements == ["Button Options", "Right Shoulder"])
        // Without the modifier, shoulder buttons are ordinary game buttons.
        let plain = engine.evaluate(heldKeys: [], heldElements: ["Right Shoulder"])
        #expect(plain.actions.isEmpty && plain.suppressedElements.isEmpty)
    }

    @Test func keyboardHotkeys() {
        let e = HotkeyEngine().evaluate(heldKeys: [48, 15, 7], heldElements: [])
        #expect(e.actions == [.fastForward, .rewind])
    }

    @Test func edgesFireOncePerPress() {
        var edges = HotkeyEdges()
        #expect(edges.update([.saveState]).pressed == [.saveState])
        #expect(edges.update([.saveState]).pressed.isEmpty)
        #expect(edges.update([]).pressed.isEmpty)
        #expect(edges.update([.saveState, .rewind]).pressed == [.saveState, .rewind])
    }

    @Test func padButtonsCodable() throws {
        // PadButtons must round trip through JSON because settings store its raw value.
        let raw: [String: UInt64] = ["x": PadButtons([.east, .start]).rawValue]
        #expect(PadButtons(rawValue: raw["x"]!) == [.east, .start])
    }
}
