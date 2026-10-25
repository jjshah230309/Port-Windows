public enum TraceError: Error, Equatable {
    case badHeader
    case badLine(Int)
}

/// Recorded controller input, one line per frame, so tests and bug reports replay exactly without hardware.
/// Line format: `buttons lx ly rx ry lt rt` (buttons as hex, floats as decimal).
public struct ControllerTrace: Equatable {
    public static let header = "attic-controller-trace 1"
    public var frames: [RawControllerState]

    public init(frames: [RawControllerState] = []) { self.frames = frames }

    public func serialized() -> String {
        var lines = [Self.header]
        for f in frames {
            lines.append([
                String(f.buttons, radix: 16),
                "\(f.leftStick.x)", "\(f.leftStick.y)", "\(f.rightStick.x)", "\(f.rightStick.y)",
                "\(f.leftTrigger)", "\(f.rightTrigger)",
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) throws -> ControllerTrace {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first.map(String.init) == header else { throw TraceError.badHeader }
        var frames: [RawControllerState] = []
        for (i, line) in lines.dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 7,
                  let buttons = UInt64(parts[0], radix: 16),
                  let lx = Float(parts[1]), let ly = Float(parts[2]),
                  let rx = Float(parts[3]), let ry = Float(parts[4]),
                  let lt = Float(parts[5]), let rt = Float(parts[6])
            else { throw TraceError.badLine(i + 2) }
            var s = RawControllerState()
            s.buttons = buttons
            s.leftStick = SIMD2(lx, ly)
            s.rightStick = SIMD2(rx, ry)
            s.leftTrigger = lt
            s.rightTrigger = rt
            frames.append(s)
        }
        return ControllerTrace(frames: frames)
    }
}

/// Plays a trace back one frame at a time. Holds the last frame once the trace ends.
public struct TraceReplayer {
    private let trace: ControllerTrace
    public private(set) var index = 0

    public init(trace: ControllerTrace) { self.trace = trace }

    public var isFinished: Bool { index >= trace.frames.count }

    public mutating func nextFrame() -> RawControllerState {
        guard !trace.frames.isEmpty else { return RawControllerState() }
        let f = trace.frames[min(index, trace.frames.count - 1)]
        index += 1
        return f
    }
}
