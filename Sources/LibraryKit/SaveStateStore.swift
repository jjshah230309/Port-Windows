import Foundation

public struct SaveStateSlot: Equatable, Sendable {
    public var slot: Int
    public var date: Date
    public var thumbnail: URL?
}

/// Save states for one game: ten numbered slots (1...10) plus slot 0 for the automatic save made when a game closes.
public final class SaveStateStore: @unchecked Sendable {
    public static let slotRange = 0...10
    public static let userSlots = 1...10

    private let directory: URL

    public init(root: URL, gameID: String) {
        directory = root.appendingPathComponent(gameID, isDirectory: true)
    }

    public func stateURL(slot: Int) -> URL { directory.appendingPathComponent("slot-\(slot).state") }
    public func thumbnailURL(slot: Int) -> URL { directory.appendingPathComponent("slot-\(slot).png") }

    public func write(slot: Int, state: [UInt8], thumbnailPNG: [UInt8]?) throws {
        precondition(Self.slotRange.contains(slot), "slot out of range")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(state).write(to: stateURL(slot: slot), options: .atomic)
        if let png = thumbnailPNG { try Data(png).write(to: thumbnailURL(slot: slot), options: .atomic) }
    }

    public func read(slot: Int) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: stateURL(slot: slot)))
    }

    public func exists(slot: Int) -> Bool { FileManager.default.fileExists(atPath: stateURL(slot: slot).path) }

    public func delete(slot: Int) {
        try? FileManager.default.removeItem(at: stateURL(slot: slot))
        try? FileManager.default.removeItem(at: thumbnailURL(slot: slot))
    }

    /// One entry per slot 0...10; nil where the slot is empty.
    public func slots() -> [SaveStateSlot?] {
        Self.slotRange.map { slot in
            let url = stateURL(slot: slot)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            let thumb = thumbnailURL(slot: slot)
            return SaveStateSlot(slot: slot, date: date,
                                 thumbnail: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil)
        }
    }
}
