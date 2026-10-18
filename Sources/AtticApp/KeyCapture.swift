import AppKit

/// Waits for the next key press (swallowing it) so the user can pick a key for a button.
@MainActor
final class KeyCapture {
    private var monitor: Any?

    func begin(_ completion: @escaping (UInt16) -> Void) {
        cancel()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let code = event.keyCode
            Task { @MainActor in
                self?.cancel()
                if code != 53 { completion(code) }      // Escape cancels
            }
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Waits for the next controller button (not a d-pad direction) to be pressed.
@MainActor
final class ControllerCapture {
    private var timer: Timer?

    func begin(poll: @escaping () -> Set<String>, _ completion: @escaping (String) -> Void) {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let pressed = poll().filter { !$0.hasPrefix("Direction Pad") }
            if let name = pressed.sorted().first {
                Task { @MainActor in
                    self?.cancel()
                    completion(name)
                }
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
