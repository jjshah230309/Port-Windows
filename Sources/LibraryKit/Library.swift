import EmuSupport
import Foundation

public struct GameRecord: Codable, Identifiable, Hashable, Sendable {
    /// SHA-1 of the ROM bytes: stable even if the file is moved or renamed.
    public var id: String
    public var title: String
    public var path: String
    public var isColor: Bool
    public var addedAt: Date
    public var lastPlayed: Date?
    public var playSeconds: Double

    public var url: URL { URL(fileURLWithPath: path) }
    public var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}

public enum LibraryError: Error, Equatable {
    case notAGameBoyROM(String)
    case unreadable(String)
}

/// The list of games the user has added, saved as JSON. The ROMs themselves are never copied or modified.
public final class LibraryStore {
    public static let romExtensions: Set<String> = ["gb", "gbc"]

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

    /// Adds (or updates the path of) the game in the file. Throws when it is not a Game Boy ROM.
    @discardableResult
    public func add(romAt url: URL, now: Date = Date()) throws -> GameRecord {
        guard let data = try? Data(contentsOf: url) else { throw LibraryError.unreadable(url.lastPathComponent) }
        let rom = [UInt8](data)
        guard let header = GameIdentity.parseHeader(rom), header.headerChecksumValid else {
            throw LibraryError.notAGameBoyROM(url.lastPathComponent)
        }
        let id = SHA1.hexDigest(rom)
        let title = header.title.isEmpty ? url.deletingPathExtension().lastPathComponent : header.title
        if let i = records.firstIndex(where: { $0.id == id }) {
            records[i].path = url.path
            records[i].title = records[i].title.isEmpty ? title : records[i].title
            return records[i]
        }
        let record = GameRecord(id: id, title: title, path: url.path, isColor: header.isColor, addedAt: now,
                                lastPlayed: nil, playSeconds: 0)
        records.append(record)
        return record
    }

    public struct ScanResult: Equatable {
        public var added: Int
        public var skipped: Int
    }

    /// Adds every Game Boy ROM found in the folder (and its subfolders). Other files are ignored.
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
