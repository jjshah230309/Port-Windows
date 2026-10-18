import EmulatorKit
import Foundation
import Synchronization

/// Newest finished video frame, handed from the emulation thread to the renderer. Copies are tiny (23 KB for a
/// Game Boy frame), so a short mutex-protected critical section is fine.
public final class FrameMailbox: @unchecked Sendable {
    private struct Storage {
        var pixels: [UInt8] = []
        var width = 0
        var height = 0
        var serial: UInt64 = 0
    }

    private let state = Mutex(Storage())

    public init() {}

    public func publish(_ frame: VideoFrame) {
        state.withLock { s in
            let bytes = frame.pitch * frame.height
            if s.pixels.count != bytes { s.pixels = [UInt8](repeating: 0, count: bytes) }
            s.pixels.withUnsafeMutableBytes { dst in
                dst.baseAddress?.copyMemory(from: frame.pixels, byteCount: bytes)
            }
            s.width = frame.width
            s.height = frame.height
            s.serial &+= 1
        }
    }

    /// Runs `body` with the newest frame (pixels, width, height, bytes per row, serial). Returns nil if none yet.
    public func withLatest<R>(_ body: (UnsafeRawPointer, Int, Int, Int, UInt64) -> R) -> R? {
        state.withLock { s in
            guard s.serial > 0, s.width > 0 else { return nil }
            return s.pixels.withUnsafeBytes { raw in
                body(raw.baseAddress!, s.width, s.height, s.width * 4, s.serial)
            }
        }
    }
}
