/// Keeps a history of save states so a game can be run backwards. Only the newest state is stored in full; each older
/// one is stored as a compressed difference (XOR + zero-run-length), so a long history of nearly identical states is small.
public struct RewindBuffer {
    private var latest: [UInt8] = []
    private var deltas: [[UInt8]] = []
    public let capacity: Int

    public init(capacity: Int) { self.capacity = max(capacity, 1) }

    /// Number of earlier states that can still be stepped back to.
    public var depth: Int { deltas.count }

    public mutating func clear() {
        latest = []
        deltas = []
    }

    public mutating func capture(_ state: [UInt8]) {
        if latest.count != state.count {
            // First capture, or a different size (a different game): start over.
            latest = state
            deltas = []
            return
        }
        deltas.append(Self.encode(old: latest, new: state))
        if deltas.count > capacity { deltas.removeFirst() }
        latest = state
    }

    /// Steps back one capture and returns that earlier state, or nil when there is no more history.
    public mutating func stepBack() -> [UInt8]? {
        guard let delta = deltas.popLast() else { return nil }
        let previous = Self.apply(delta: delta, to: latest)
        latest = previous
        return previous
    }

    // MARK: Delta coding: repeated [zero-run varint, literal-length varint, literal bytes], covering the whole state.

    static func encode(old: [UInt8], new: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        let n = new.count
        while i < n {
            var zeros = 0
            while i < n && old[i] == new[i] { zeros += 1; i += 1 }
            var literal: [UInt8] = []
            while i < n && old[i] != new[i] { literal.append(old[i] ^ new[i]); i += 1 }
            appendVarint(&out, zeros)
            appendVarint(&out, literal.count)
            out += literal
        }
        return out
    }

    static func apply(delta: [UInt8], to state: [UInt8]) -> [UInt8] {
        var out = state
        var pos = 0
        var i = 0
        while pos < delta.count {
            i += readVarint(delta, &pos)
            let literal = readVarint(delta, &pos)
            for k in 0..<literal { out[i + k] ^= delta[pos + k] }
            pos += literal
            i += literal
        }
        return out
    }

    private static func appendVarint(_ out: inout [UInt8], _ value: Int) {
        var v = value
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }

    private static func readVarint(_ bytes: [UInt8], _ pos: inout Int) -> Int {
        var value = 0, shift = 0
        while true {
            let b = bytes[pos]
            pos += 1
            value |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
        }
    }
}
