import EmulatorKit
import Foundation
import Synchronization

private struct SendableBox<T>: @unchecked Sendable { let value: T }

/// Runs one emulator core on a dedicated thread: runs frames, feeds audio and video, and paces itself to the
/// core's native frame rate, nudged by the audio buffer fill (dynamic rate control) so audio never drifts.
public final class EmulationSession: @unchecked Sendable {
    private let core: SendableBox<any EmulatorCore>
    private let input: SendableBox<any InputSource>
    private let output: SendableBox<any OutputSink>
    private let audio: AudioOutput?
    private let frames: FrameMailbox
    private let info: SystemInfo
    private let stopFlag = Atomic<Bool>(false)
    private let pauseFlag = Atomic<Bool>(false)
    private let fastForwardFlag = Atomic<Bool>(false)
    private let resetFlag = Atomic<Bool>(false)
    private var thread: Thread?
    /// Called on the emulation thread about once a second when battery RAM changed; write it to disk there.
    public var onBatterySave: (@Sendable ([UInt8]) -> Void)?

    public init(core: any EmulatorCore, input: any InputSource, output: any OutputSink,
                audio: AudioOutput?, frames: FrameMailbox) {
        self.core = SendableBox(value: core)
        self.input = SendableBox(value: input)
        self.output = SendableBox(value: output)
        self.audio = audio
        self.frames = frames
        info = type(of: core).info
    }

    public var isPaused: Bool { pauseFlag.load(ordering: .relaxed) }
    public func setPaused(_ paused: Bool) { pauseFlag.store(paused, ordering: .relaxed) }
    public func setFastForward(_ on: Bool) { fastForwardFlag.store(on, ordering: .relaxed) }
    public func requestReset() { resetFlag.store(true, ordering: .relaxed) }

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [self] in run() }
        t.name = "Emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops the thread and waits for it to finish, then flushes battery RAM.
    public func stop() {
        stopFlag.store(true, ordering: .relaxed)
        while thread?.isFinished == false || thread?.isExecuting == true { Thread.sleep(forTimeInterval: 0.002) }
        thread = nil
        flushBattery()
    }

    private func flushBattery() {
        let core = core.value
        if let save = core.batterySave, save.isDirty {
            onBatterySave?(save.bytes)
            core.markBatterySaved()
        }
    }

    private func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func run() {
        let core = core.value
        let input = input.value
        let output = output.value
        let baseFrame = 1e9 / info.framesPerSecond
        var next = nowNanos()
        var frameCount = 0
        while !stopFlag.load(ordering: .relaxed) {
            if pauseFlag.load(ordering: .relaxed) {
                Thread.sleep(forTimeInterval: 0.01)
                next = nowNanos()
                continue
            }
            if resetFlag.exchange(false, ordering: .relaxed) { core.reset(hard: false) }

            core.runFrame(input: input, output: output)
            core.drainAudio { samples in
                if let audio = self.audio, !self.fastForwardFlag.load(ordering: .relaxed) { audio.push(samples) }
            }
            frames.publish(core.video)

            frameCount += 1
            if frameCount % 60 == 0 { flushBattery() }

            if fastForwardFlag.load(ordering: .relaxed) {
                next = nowNanos()
                continue
            }
            // Dynamic rate control: a fuller audio buffer means we are running ahead, so slow down a little.
            var period = baseFrame
            if let audio {
                let error = audio.ring.fillFraction - 0.5
                period *= 1.0 + max(-0.5, min(0.5, error)) * 0.01
            }
            next += UInt64(period)
            let now = nowNanos()
            if next > now {
                let wait = Double(next - now) / 1e9
                if wait > 0.002 { Thread.sleep(forTimeInterval: wait - 0.001) }
                while nowNanos() < next { }       // short spin for the last millisecond
            } else if now - next > UInt64(baseFrame * 5) {
                next = now                         // fell far behind (for example after a stall): do not rush to catch up
            }
        }
    }
}
