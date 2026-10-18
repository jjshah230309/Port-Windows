import AVFoundation
import Synchronization

/// Plays the emulator's audio through AVAudioEngine. The render callback only reads the lock-free ring.
public final class AudioOutput: @unchecked Sendable {
    public let ring: AudioRing
    public let sampleRate: Double
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let underrunCounter = Atomic<Int>(0)

    public init(sampleRate: Double = 48_000, ringFrames: Int = 16_384) {
        self.sampleRate = sampleRate
        ring = AudioRing(capacityFrames: ringFrames)
    }

    /// How many times the callback ran out of samples (shown in a debug HUD later).
    public var underruns: Int { underrunCounter.load(ordering: .relaxed) }

    public func start() throws {
        guard node == nil else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            return
        }
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let wanted = Int(frameCount)
            let got = ring.read(left: left, right: right, frames: wanted)
            if got < wanted {
                for i in got..<wanted { left[i] = 0; right[i] = 0 }
                _ = self?.underrunCounter.wrappingAdd(1, ordering: .relaxed)
            }
            return noErr
        }
        node = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    public func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }

    /// Called from the emulation thread with interleaved stereo Int16 samples.
    public func push(_ samples: UnsafeBufferPointer<Int16>) {
        ring.write(samples)
    }
}
