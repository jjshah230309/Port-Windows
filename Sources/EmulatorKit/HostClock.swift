#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Injected wall clock, so cartridge real-time clocks are deterministic in tests.
public protocol HostClock: Sendable {
    func unixSeconds() -> Int64
}

public struct SystemClock: HostClock {
    public init() {}
    public func unixSeconds() -> Int64 { Int64(time(nil)) }
}

public struct FixedClock: HostClock {
    public var seconds: Int64
    public init(seconds: Int64) { self.seconds = seconds }
    public func unixSeconds() -> Int64 { seconds }
}
