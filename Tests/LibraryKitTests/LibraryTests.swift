import Foundation
import Testing
import EmulatorKit
import EmuSupport
@testable import LibraryKit

/// A fake ROM with a valid header (title, checksum) and distinguishing content.
private func makeROM(title: String, color: Bool = false, salt: UInt8 = 0, valid: Bool = true) -> [UInt8] {
    var rom = [UInt8](repeating: salt, count: 0x8000)
    for (i, c) in title.utf8.enumerated() where i < 15 { rom[0x134 + i] = c }
    for i in title.utf8.count..<15 { rom[0x134 + i] = 0 }
    rom[0x143] = color ? 0x80 : 0
    var checksum: UInt8 = 0
    for i in 0x134...0x14C { checksum = checksum &- rom[i] &- 1 }
    rom[0x14D] = valid ? checksum : checksum &+ 1
    return rom
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct LibraryTests {
    @Test func parsesHeader() throws {
        let h = try #require(GameIdentity.parseHeader(makeROM(title: "TETRIS", color: false)))
        #expect(h.title == "TETRIS" && !h.isColor && h.headerChecksumValid)
        let c = try #require(GameIdentity.parseHeader(makeROM(title: "ZELDA DX", color: true)))
        #expect(c.isColor)
        #expect(GameIdentity.parseHeader([1, 2, 3]) == nil)
        #expect(!GameIdentity.looksLikeGameBoyROM(makeROM(title: "BAD", valid: false)))
    }

    @Test func addsDeduplicatesAndPersists() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.gb"), copy = dir.appendingPathComponent("a copy.gb")
        try Data(makeROM(title: "GAME A")).write(to: a)
        try Data(makeROM(title: "GAME A")).write(to: copy)              // identical bytes
        let store = LibraryStore(fileURL: dir.appendingPathComponent("library.json"))
        let r1 = try store.add(romAt: a)
        let r2 = try store.add(romAt: copy)
        #expect(r1.id == r2.id && store.records.count == 1)             // same ROM, one entry
        #expect(store.records[0].path == copy.path)                     // path follows the latest file
        try store.save()
        let reloaded = LibraryStore(fileURL: dir.appendingPathComponent("library.json"))
        #expect(reloaded.records.count == 1 && reloaded.records[0].title == "GAME A")
    }

    @Test func rejectsNonROMs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("junk.gb")
        try Data(makeROM(title: "BAD", valid: false)).write(to: bad)
        let store = LibraryStore(fileURL: dir.appendingPathComponent("l.json"))
        #expect(throws: LibraryError.notAGameBoyROM("junk.gb")) { try store.add(romAt: bad) }
    }

    @Test func scansFoldersRecursively() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("more/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(makeROM(title: "ONE", salt: 1)).write(to: dir.appendingPathComponent("one.gb"))
        try Data(makeROM(title: "TWO", color: true, salt: 2)).write(to: sub.appendingPathComponent("two.GBC"))
        try Data(makeROM(title: "BAD", valid: false)).write(to: dir.appendingPathComponent("bad.gb"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let store = LibraryStore(fileURL: dir.appendingPathComponent("l.json"))
        let result = store.scan(directory: dir)
        #expect(result == LibraryStore.ScanResult(added: 2, skipped: 1))
        #expect(Set(store.records.map(\.title)) == ["ONE", "TWO"])
        #expect(store.scan(directory: dir).added == 0)                  // second scan finds nothing new
    }

    @Test func ordersByLastPlayed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["ALPHA", "BETA", "GAMMA"].enumerated() {
            try Data(makeROM(title: name, salt: UInt8(i + 1))).write(to: dir.appendingPathComponent("\(name).gb"))
        }
        let store = LibraryStore(fileURL: dir.appendingPathComponent("l.json"))
        store.scan(directory: dir)
        #expect(store.sorted.map(\.title) == ["ALPHA", "BETA", "GAMMA"])
        let gamma = try #require(store.records.first { $0.title == "GAMMA" })
        store.markPlayed(id: gamma.id, seconds: 90, at: Date(timeIntervalSince1970: 2_000))
        let beta = try #require(store.records.first { $0.title == "BETA" })
        store.markPlayed(id: beta.id, seconds: 10, at: Date(timeIntervalSince1970: 1_000))
        #expect(store.sorted.map(\.title) == ["GAMMA", "BETA", "ALPHA"])
        #expect(store.record(id: gamma.id)?.playSeconds == 90)
    }

    @Test func corruptLibraryIsSetAside() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        try Data("{ not json".utf8).write(to: file)
        let store = LibraryStore(fileURL: file)
        #expect(store.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
    }
}

@Suite struct SaveStateStoreAndSettingsTests {
    @Test func slotsRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SaveStateStore(root: dir, gameID: "abc123")
        #expect(store.slots().allSatisfy { $0 == nil })
        let png: [UInt8] = [1, 2, 3]
        try store.write(slot: 3, state: [9, 8, 7], thumbnailPNG: png)
        try store.write(slot: 0, state: [5], thumbnailPNG: nil)
        #expect(try store.read(slot: 3) == [9, 8, 7])
        let slots = store.slots()
        #expect(slots.count == 11)
        #expect(slots[3]?.thumbnail != nil && slots[0]?.thumbnail == nil)
        #expect(slots[1] == nil)
        store.delete(slot: 3)
        #expect(!store.exists(slot: 3) && store.slots()[3] == nil)
        #expect(throws: (any Error).self) { _ = try store.read(slot: 3) }
    }

    @Test func settingsPersistAndOverride() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: file)
        #expect(store.settings.scaling == "integer")
        store.settings.scaling = "sharpBilinear"
        store.settings.volume = 0.5
        store.settings.keyboardOverrides = ["0": PadButtons.east.rawValue]
        store.settings.perGame["abc"] = GameSettings(palette: "green")
        try store.save()
        let again = SettingsStore(fileURL: file).settings
        #expect(again.scaling == "sharpBilinear" && again.volume == 0.5)
        #expect(again.effectivePalette(for: "abc") == "green" && again.effectivePalette(for: "other") == "gray")
        #expect(again.effectiveScaling(for: "abc") == "sharpBilinear")
    }

    @Test func corruptSettingsFallBackToDefaults() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try Data("garbage".utf8).write(to: file)
        #expect(SettingsStore(fileURL: file).settings == AppSettings())
    }
}
