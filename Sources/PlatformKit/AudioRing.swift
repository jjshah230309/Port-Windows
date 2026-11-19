import Synchronization

/// Lock-free single-producer / single-consumer ring of stereo frames. The emulation thread writes interleaved Int16
/// samples; the audio render callback reads them as Float, without locks or allocation.
public final class AudioRing: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let head = Atomic<Int>(0)     // total frames written (producer)
    private let tail = Atomic<Int>(0)     // total frames read (consumer)

    public init(capacityFrames: Int = 16_384) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c * 2)
        storage.initialize(repeating: 0, count: c * 2)
    }

    deinit { storage.deallocate() }

    public var capacityFrames: Int { capacity }

    public var availableFrames: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }

    /// 0...1 fill level, used for dynamic rate control.
    public var fillFraction: Double { Double(availableFrames) / Double(capacity) }

    /// Writes interleaved stereo samples; returns the number of frames accepted (the rest are dropped).
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Int16>) -> Int {
        let frames = samples.count / 2
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n = min(frames, capacity - (h - t))
        for i in 0..<max(n, 0) {
            let idx = ((h + i) & mask) * 2
            storage[idx] = samples[i * 2]
            storage[idx + 1] = samples[i * 2 + 1]
        }
        head.store(h + max(n, 0), ordering: .releasing)
        return max(n, 0)
    }

    /// Reads up to `frames` frames into separate left/right float buffers; returns the number read.
    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(frames, h - t)
        for i in 0..<max(n, 0) {
            let idx = ((t + i) & mask) * 2
            left[i] = Float(storage[idx]) * (1.0 / 32768.0)
            right[i] = Float(storage[idx + 1]) * (1.0 / 32768.0)
        }
        tail.store(t + max(n, 0), ordering: .releasing)
        return max(n, 0)
    }
}
