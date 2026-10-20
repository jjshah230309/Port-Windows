import EmuSupport
import Foundation

/// A system whose games the library can hold. New systems (PS1, ...) are added here.
public enum LibrarySystem: String, Codable, CaseIterable, Sendable {
    case gameBoy
    case gameBoyAdvance

    /// How the system is shown to the user.
    public var displayName: String {
        switch self {
        case .gameBoy: "Game Boy"
        case .gameBoyAdvance: "Game Boy Advance"
        }
    }

    /// The file extensions this system owns, lowercased.
    public var romExtensions: Set<String> {
        switch self {
        case .gameBoy: ["gb", "gbc"]
        case .gameBoyAdvance: ["gba"]
        }
    }

    /// The system that claims a file extension, if any.
    public static func system(forExtension ext: String) -> LibrarySystem? {
        let ext = ext.lowercased()
        return allCases.first { $0.romExtensions.contains(ext) }
    }
}

public struct GameRecord: Codable, Identifiable, Hashable, Sendable {
    /// SHA-1 of the ROM bytes: stable even if the file is moved or renamed.
    public var id: String
    public var title: String
    public var path: String
    public var isColor: Bool
    /// The system the game runs on. Libraries written before this field existed hold Game Boy games.
    public var system: LibrarySystem
    public var addedAt: Date
    public var lastPlayed: Date?
    public var playSeconds: Double

    public var url: URL { URL(fileURLWithPath: path) }
    public var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }

    public init(id: String, title: String, path: String, isColor: Bool, system: LibrarySystem = .gameBoy,
                addedAt: Date, lastPlayed: Date?, playSeconds: Double) {
        self.id = id
        self.title = title
        self.path = path
        self.isColor = isColor
        self.system = system
        self.addedAt = addedAt
        self.lastPlayed = lastPlayed
        self.playSeconds = playSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, path, isColor, system, addedAt, lastPlayed, playSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        path = try c.decode(String.self, forKey: .path)
        isColor = try c.decode(Bool.self, forKey: .isColor)
        // Libraries saved before systems were tracked have no such field: they are all Game Boy.
        system = try c.decodeIfPresent(LibrarySystem.self, forKey: .system) ?? .gameBoy
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        playSeconds = try c.decode(Double.self, forKey: .playSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(path, forKey: .path)
        try c.encode(isColor, forKey: .isColor)
        try c.encode(system, forKey: .system)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try c.encode(playSeconds, forKey: .playSeconds)
    }
}

public enum LibraryError: Error, Equatable {
    case notAGameBoyROM(String)
    case notAGameBoyAdvanceROM(String)
    case unreadable(String)

    /// The error to report for a file that does not pass a system's own header check.
    public static func notAROM(_ name: String, system: LibrarySystem) -> LibraryError {
        switch system {
        case .gameBoy: .notAGameBoyROM(name)
        case .gameBoyAdvance: .notAGameBoyAdvanceROM(name)
        }
    }
}

/// The list of games the user has added, saved as JSON. The ROMs themselves are never copied or modified.
public final class LibraryStore {
    /// Every file extension the library recognises, across all systems.
    public static let romExtensions: Set<String> =
        LibrarySystem.allCases.reduce(into: Set<String>()) { $0.formUnion($1.romExtensions) }

    private let fileURL: URL
    public private(set) var records: [GameRecord] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Newest-played first, then alphabetical.
    public var sorted: [GameRecord] {
        records.sorted {
            switch ($0.lastPlayed, $1.lastPlayed) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    public func record(id: String) -> GameRecord? { records.first { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([GameRecord].self, from: data) {
            records = list
        } else {
            // Keep an unreadable file for inspection rather than overwriting it silently.
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("corrupt"))
        }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }

    /// Adds (or updates the path of) the game in the file. Throws when it is not a ROM the library knows.
    @discardableResult
    public func add(romAt url: URL, now: Date = Date()) throws -> GameRecord {
        guard let data = try? Data(contentsOf: url) else { throw LibraryError.unreadable(url.lastPathComponent) }
        let rom = [UInt8](data)
        // The extension says which system the file claims to be; the header has the last word.
        let claimed = LibrarySystem.system(forExtension: url.pathExtension) ?? .gameBoy
        guard let game = GameIdentity.identify(rom, preferred: claimed) else {
            throw LibraryError.notAROM(url.lastPathComponent, system: claimed)
        }
        let id = SHA1.hexDigest(rom)
        let title = game.title.isEmpty ? url.deletingPathExtension().lastPathComponent : game.title
        if let i = records.firstIndex(where: { $0.id == id }) {
            records[i].path = url.path
            records[i].title = records[i].title.isEmpty ? title : records[i].title
            records[i].system = game.system
            return records[i]
        }
        let record = GameRecord(id: id, title: title, path: url.path, isColor: game.isColor, system: game.system,
                                addedAt: now, lastPlayed: nil, playSeconds: 0)
        records.append(record)
        return record
    }

    public struct ScanResult: Equatable {
        public var added: Int
        public var skipped: Int
    }

    /// Adds every ROM found in the folder (and its subfolders). Other files are ignored.
    @discardableResult
    public func scan(directory: URL, now: Date = Date()) -> ScanResult {
        var result = ScanResult(added: 0, skipped: 0)
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in e where Self.romExtensions.contains(url.pathExtension.lowercased()) {
            let before = records.count
            do {
                try add(romAt: url, now: now)
                if records.count > before { result.added += 1 }
            } catch {
                result.skipped += 1
            }
        }
        return result
    }

    public func markPlayed(id: String, seconds: Double = 0, at date: Date = Date()) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].lastPlayed = date
        records[i].playSeconds += seconds
    }

    public func remove(id: String) { records.removeAll { $0.id == id } }
}
