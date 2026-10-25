import Synchronization

/// Hand-off of the newest controller sample from the input queue to the emulation thread.
/// M0 uses a mutex-guarded slot (correct and uncontended in practice); a seqlock can replace it if profiling asks for it.
public final class InputMailbox: Sendable {
    private struct Slot {
        var state = RawControllerState()
        var sequence: UInt64 = 0
    }

    private let slot = Mutex(Slot())

    public init() {}

    public func publish(_ state: RawControllerState) {
        slot.withLock {
            $0.state = state
            $0.sequence &+= 1
        }
    }

    /// The newest sample and how many were published in total (so callers can detect "nothing new").
    public func latest() -> (state: RawControllerState, sequence: UInt64) {
        slot.withLock { ($0.state, $0.sequence) }
    }
}

/// Rumble and light requests from the core, coalesced and delivered to hardware off the emulation thread.
public final class OutputMailbox: Sendable {
    public struct Request: Sendable, Equatable {
        public var rumbleLow: Float = 0
        public var rumbleHigh: Float = 0
        public init() {}
    }

    private let slot = Mutex(Request())

    public init() {}

    public func set(low: Float, high: Float) {
        slot.withLock {
            $0.rumbleLow = low
            $0.rumbleHigh = high
        }
    }

    public func current() -> Request { slot.withLock { $0 } }
}
