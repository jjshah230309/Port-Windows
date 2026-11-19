public enum PixelFormat: Sendable { case bgra8 }

/// A finished frame. The pointer is valid until the next `runFrame`.
public struct VideoFrame {
    public var pixels: UnsafeRawPointer
    public var width: Int
    public var height: Int
    public var pitch: Int
    public var format: PixelFormat

    public init(pixels: UnsafeRawPointer, width: Int, height: Int, pitch: Int, format: PixelFormat = .bgra8) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.pitch = pitch
        self.format = format
    }
}

/// A disc image seen as 2352-byte raw sectors (cores read what they need).
public protocol DiscSource: AnyObject {
    var sectorCount: Int { get }
    func readRawSector(_ lba: Int, into buffer: UnsafeMutableRawPointer) -> Bool
}

public enum MediaSource {
    case rom([UInt8])
    case disc(any DiscSource)
}

/// BIOS and other user-supplied firmware, by logical name (e.g. "bios").
public struct FirmwareSet: Sendable {
    public var files: [String: [UInt8]]
    public init(files: [String: [UInt8]] = [:]) { self.files = files }
}

public struct CoreOptions: Sendable {
    public var values: [String: String]
    public init(values: [String: String] = [:]) { self.values = values }
}

/// The contract every emulator core implements.
/// A core is owned by exactly one dedicated emulation thread and is deliberately not `Sendable`.
public protocol EmulatorCore: AnyObject {
    static var info: SystemInfo { get }

    init(media: MediaSource, firmware: FirmwareSet, options: CoreOptions, clock: any HostClock) throws

    func reset(hard: Bool)
    /// Runs one video frame. Input is latched lazily on the first guest pad read; rumble goes to `output`.
    func runFrame(input: any InputSource, output: any OutputSink)

    var video: VideoFrame { get }
    /// Interleaved stereo Int16 at `info.audioRate`.
    func drainAudio(_ sink: (UnsafeBufferPointer<Int16>) -> Void)
    /// Battery-backed save data and a dirty flag, if the media has any.
    var batterySave: BatterySave? { get }
    /// Clears the dirty flag after the host has written `batterySave` to disk.
    func markBatterySaved()
    /// Restores previously saved battery data.
    func loadBatterySave(_ bytes: [UInt8])

    func saveState(into writer: inout StateWriter)
    func loadState(from reader: inout StateReader) throws
}

public struct BatterySave {
    public var bytes: [UInt8]
    public var isDirty: Bool
    public init(bytes: [UInt8], isDirty: Bool) {
        self.bytes = bytes
        self.isDirty = isDirty
    }
}
