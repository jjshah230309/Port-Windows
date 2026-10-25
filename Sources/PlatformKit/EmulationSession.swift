import ControllerModel
import EmuSupport
import EmulatorKit
import Foundation
import LibraryKit
import Synchronization

private struct SendableBox<T>: @unchecked Sendable { let value: T }

/// Runs one emulator core on a dedicated thread: runs frames, feeds audio and video, paces itself to the core's native
/// frame rate (nudged by the audio buffer fill so audio never drifts), and handles save states, rewind and hotkeys.
public final class EmulationSession: @unchecked Sendable {
    private enum Command: Sendable { case save(Int), load(Int), reset }

    private let core: SendableBox<any EmulatorCore>
    private let input: SendableBox<any InputSource>
    private let output: SendableBox<any OutputSink>
    private let audio: AudioOutput?
    private let frames: FrameMailbox
    private let info: SystemInfo
    private let gameHash: UInt64
    private let store: SaveStateStore?
    private let stopFlag = Atomic<Bool>(false)
    private let pauseFlag = Atomic<Bool>(false)
    private let fastForwardFlag = Atomic<Bool>(false)
    private let slotValue = Atomic<Int>(1)
    private let commands = Mutex<[Command]>([])
    private var thread: Thread?
    private var framesRun = 0

    /// Called on the emulation thread about once a second when battery RAM changed; write it to disk there.
    public var onBatterySave: (@Sendable ([UInt8]) -> Void)?
    /// Short user-facing notices such as "Saved to slot 3". Called on the emulation thread.
    public var onMessage: (@Sendable (String) -> Void)?
    /// Polled once per frame on the emulation thread: the hotkey actions currently held down.
    public var hotkeys: (@Sendable () -> Set<HotkeyAction>)?

    public init(core: any EmulatorCore, input: any InputSource, output: any OutputSink, audio: AudioOutput?,
                frames: FrameMailbox, gameHash: UInt64, stateStore: SaveStateStore?) {
        self.core = SendableBox(value: core)
        self.input = SendableBox(value: input)
        self.output = SendableBox(value: output)
        self.audio = audio
        self.frames = frames
        self.gameHash = gameHash
        store = stateStore
        info = type(of: core).info
    }

    // MARK: Controls (callable from any thread)

    public var isPaused: Bool { pauseFlag.load(ordering: .relaxed) }
    public func setPaused(_ paused: Bool) { pauseFlag.store(paused, ordering: .relaxed) }
    public func setFastForward(_ on: Bool) { fastForwardFlag.store(on, ordering: .relaxed) }
    public func requestReset() { enqueue(.reset) }
    public func saveState(slot: Int) { enqueue(.save(slot)) }
    public func loadState(slot: Int) { enqueue(.load(slot)) }

    /// The slot used by the save and load hotkeys, 1...10.
    public var currentSlot: Int {
        get { slotValue.load(ordering: .relaxed) }
        set { slotValue.store(min(max(newValue, 1), 10), ordering: .relaxed) }
    }

    private func enqueue(_ c: Command) { commands.withLock { $0.append(c) } }

    // MARK: Lifecycle

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [self] in run() }
        t.name = "Emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops the thread and waits for it, then writes the automatic save state (slot 0) and flushes battery RAM.
    public func stop() {
        stopFlag.store(true, ordering: .relaxed)
        while thread?.isFinished == false || thread?.isExecuting == true { Thread.sleep(forTimeInterval: 0.002) }
        thread = nil
        // The emulation thread has ended, so the core can be used from here without racing it.
        if framesRun > 0, let store { try? writeState(to: store, slot: 0) }
        flushBattery()
    }

    private func flushBattery() {
        let core = core.value
        if let save = core.batterySave, save.isDirty {
            onBatterySave?(save.bytes)
            core.markBatterySaved()
        }
    }

    // MARK: States

    private func captureStateBytes() -> [UInt8] {
        var writer = StateWriter(system: info.id, gameHash: gameHash)
        core.value.saveState(into: &writer)
        return writer.bytes
    }

    private func writeState(to store: SaveStateStore, slot: Int) throws {
        let v = core.value.video
        let png = PNGEncoder.encode(bgra: UnsafeRawBufferPointer(start: v.pixels, count: v.pitch * v.height),
                                    width: v.width, height: v.height, bytesPerRow: v.pitch)
        try store.write(slot: slot, state: captureStateBytes(), thumbnailPNG: png)
    }

    private func restoreState(_ bytes: [UInt8]) throws {
        var reader = try StateReader(bytes: bytes)
        guard reader.system == info.id, reader.gameHash == gameHash else { throw StateError.badMagic }
        try core.value.loadState(from: &reader)
    }

    private func perform(_ command: Command, rewind: inout RewindBuffer) {
        switch command {
        case .reset:
            core.value.reset(hard: false)
            rewind.clear()
        case .save(let slot):
            guard let store else { return }
            do {
                try writeState(to: store, slot: slot)
                onMessage?("Saved to slot \(slot)")
            } catch {
                onMessage?("Could not save to slot \(slot)")
            }
        case .load(let slot):
            guard let store, store.exists(slot: slot) else { onMessage?("Slot \(slot) is empty"); return }
            do {
                try restoreState(try store.read(slot: slot))
                rewind.clear()
                frames.publish(core.value.video)
                onMessage?(slot == 0 ? "Resumed from the automatic save" : "Loaded slot \(slot)")
            } catch {
                onMessage?("Could not load slot \(slot) (saved by a different game or version?)")
            }
        }
    }

    // MARK: Main loop

    private func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func run() {
        let core = core.value
        let input = input.value
        let output = output.value
        let baseFrame = 1e9 / info.framesPerSecond
        var next = nowNanos()
        var edges = HotkeyEdges()
        var rewind = RewindBuffer(capacity: 600)          // 600 captures, two frames apart: about 20 seconds
        var wasRewinding = false

        while !stopFlag.load(ordering: .relaxed) {
            let queued = commands.withLock { c -> [Command] in
                let all = c
                c.removeAll()
                return all
            }
            for c in queued { perform(c, rewind: &rewind) }

            let result = edges.update(hotkeys?() ?? [])
            if result.pressed.contains(.pause) { setPaused(!isPaused) }
            if result.pressed.contains(.saveState) { perform(.save(currentSlot), rewind: &rewind) }
            if result.pressed.contains(.loadState) { perform(.load(currentSlot), rewind: &rewind) }
            if result.pressed.contains(.reset) { perform(.reset, rewind: &rewind) }
            if result.pressed.contains(.nextSlot) { currentSlot += 1; onMessage?("Slot \(currentSlot)") }
            if result.pressed.contains(.previousSlot) { currentSlot -= 1; onMessage?("Slot \(currentSlot)") }
            let rewinding = result.held.contains(.rewind)
            let fastForward = result.held.contains(.fastForward) || fastForwardFlag.load(ordering: .relaxed)

            if pauseFlag.load(ordering: .relaxed) {
                Thread.sleep(forTimeInterval: 0.01)
                next = nowNanos()
                continue
            }

            if rewinding {
                // Step back through captured history; each step undoes about two frames of play.
                if let previous = rewind.stepBack() {
                    try? restoreState(previous)
                    frames.publish(core.video)
                }
                wasRewinding = true
            } else {
                if wasRewinding { wasRewinding = false }
                core.runFrame(input: input, output: output)
                framesRun += 1
                core.drainAudio { samples in
                    if let audio = self.audio, !fastForward { audio.push(samples) }
                }
                frames.publish(core.video)
                if framesRun % 2 == 0 { rewind.capture(captureStateBytes()) }
                if framesRun % 60 == 0 { flushBattery() }
            }

            if fastForward && !rewinding {
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
