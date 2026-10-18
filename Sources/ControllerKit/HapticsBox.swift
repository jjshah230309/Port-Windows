import CoreHaptics
import GameController

/// One continuous haptic event whose intensity is updated every time the cartridge's rumble level changes.
final class CHHapticEngineBox {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var playing = false

    init?(controller: GCController) {
        guard let haptics = controller.haptics, let engine = haptics.createEngine(withLocality: .default) else { return nil }
        self.engine = engine
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                                      relativeTime: 0, duration: GCHapticDurationInfinite)
            player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
        } catch {
            return nil
        }
    }

    func set(intensity: Float) {
        guard let player else { return }
        do {
            if intensity <= 0 {
                if playing { try player.stop(atTime: CHHapticTimeImmediate); playing = false }
                return
            }
            if !playing { try player.start(atTime: CHHapticTimeImmediate); playing = true }
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(intensity, 1),
                                                               relativeTime: 0)], atTime: CHHapticTimeImmediate)
        } catch {
            // The controller may have disconnected; the next level change retries.
        }
    }
}
