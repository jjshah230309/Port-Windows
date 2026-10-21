import AppKit
import ControllerKit
import ControllerModel
import EmuSupport
import EmulatorKit
import Foundation
import GBCore
import LibraryKit
import PlatformKit
import UniformTypeIdentifiers

/// Owns the library, settings and the running game: the core, the emulation thread, audio, video and input.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Published state
    @Published var title = "Attic"
    @Published private(set) var current: GameRecord?
    @Published var errorMessage: String?
    @Published var isPaused = false
    @Published private(set) var games: [GameRecord] = []
    @Published var selectedGameID: String?
    @Published var toast: String?
    @Published private(set) var currentSlot = 1
    @Published var settings = AppSettings()

    // MARK: Subsystems
    let mailbox = FrameMailbox()
    let input = HostInput()
    let output = HostOutput()
    let audio = AudioOutput()
    private(set) var gameView: GameView?
    private var session: EmulationSession?
    private var launchHandled = false
    private var playStart: Date?
    private var toastTask: Task<Void, Never>?

    // MARK: Storage
    private let supportDirectory: URL
    private let library: LibraryStore
    private let settingsStore: SettingsStore
    private var stateStore: SaveStateStore?

    var isPlaying: Bool { session != nil }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        supportDirectory = base.appendingPathComponent("Attic", isDirectory: true)
        library = LibraryStore(fileURL: supportDirectory.appendingPathComponent("library.json"))
        settingsStore = SettingsStore(fileURL: supportDirectory.appendingPathComponent("settings.json"))
        settings = settingsStore.settings
        games = library.sorted
        gameView = GameView(mailbox: mailbox)
        gameView?.keyHandler = { [weak self] event, down in self?.input.keyboard.handle(keyCode: event.keyCode, down: down) }
        applySettings()
    }

    // MARK: Settings

    /// Pushes the saved settings into the live input, audio and video objects.
    func applySettings() {
        input.keyboard.bindings = KeyboardBindings(overrides: settings.keyboardOverrides)
        input.gamepad.bindings = GamepadBindings(overrides: settings.gamepadOverrides)
        audio.setVolume(settings.volume, muted: settings.muted)
        gameView?.scalingMode = (current.map { settings.effectiveScaling(for: $0.id) } ?? settings.scaling) == "sharpBilinear"
            ? .sharpBilinear : .integer
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        settingsStore.settings = settings
        try? settingsStore.save()
        applySettings()
    }

    // MARK: Library

    func presentAddGamePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LibraryStore.romExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Choose Game Boy, Game Boy Color or Game Boy Advance games you own"
        if panel.runModal() == .OK { for url in panel.urls { addGame(url: url) } }
    }

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder to search for Game Boy, Game Boy Color and Game Boy Advance games"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = library.scan(directory: url)
        persistLibrary()
        show("Added \(result.added) game\(result.added == 1 ? "" : "s")" + (result.skipped > 0 ? ", skipped \(result.skipped) invalid file(s)" : ""))
    }

    @discardableResult
    func addGame(url: URL) -> GameRecord? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let result = library.scan(directory: url)
            persistLibrary()
            show("Added \(result.added) game\(result.added == 1 ? "" : "s")")
            return nil
        }
        do {
            let record = try library.add(romAt: url)
            persistLibrary()
            return record
        } catch LibraryError.notAGameBoyROM(let name) {
            errorMessage = "\(name) is not a Game Boy or Game Boy Color game."
        } catch LibraryError.notAGameBoyAdvanceROM(let name) {
            errorMessage = "\(name) is not a Game Boy Advance game."
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent)."
        }
        return nil
    }

    func removeFromLibrary(_ record: GameRecord) {
        library.remove(id: record.id)
        persistLibrary()
    }

    private func persistLibrary() {
        try? library.save()
        games = library.sorted
        if selectedGameID == nil { selectedGameID = games.first?.id }
    }

    func thumbnail(for record: GameRecord) -> NSImage? {
        let store = SaveStateStore(root: supportDirectory.appendingPathComponent("states"), gameID: record.id)
        let newest = store.slots().compactMap { $0 }.filter { $0.thumbnail != nil }.max { $0.date < $1.date }
        return newest?.thumbnail.flatMap { NSImage(contentsOf: $0) }
    }

    func hasAutoSave(_ record: GameRecord) -> Bool {
        SaveStateStore(root: supportDirectory.appendingPathComponent("states"), gameID: record.id).exists(slot: 0)
    }

    /// Whether the core for this game's system can actually run it yet. The Game Boy Advance
    /// core has its memory map and its cartridge layer but no CPU, so it cannot play a game.
    func canPlay(_ record: GameRecord) -> Bool {
        record.system == .gameBoy
    }

    /// A file or folder dropped on the window: folders are scanned, a single game is added and started.
    func handleDrop(url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            _ = addGame(url: url)
        } else {
            open(url: url)
        }
    }

    // MARK: Playing

    /// Handles `Attic --open <path>` once, after the window exists.
    func openFromArguments() {
        guard !launchHandled else { return }
        launchHandled = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            open(url: URL(fileURLWithPath: args[i + 1]))
        }
    }

    /// Adds the file to the library (if it is a game) and starts it.
    func open(url: URL) {
        if let record = addGame(url: url) { play(record) }
    }

    func play(_ record: GameRecord, resumeAutoSave: Bool = false) {
        stop()
        errorMessage = nil
        do {
            let data = try Data(contentsOf: record.url)
            let rom = [UInt8](data)
            var options: [String: String] = [:]
            if settings.effectivePalette(for: record.id) == "green" { options["palette"] = "green" }
            let core: any EmulatorCore
            switch record.system {
            case .gameBoy:
                core = try GameBoyCore(media: .rom(rom), firmware: FirmwareSet(), options: CoreOptions(values: options),
                                       clock: SystemClock())
            case .gameBoyAdvance:
                // The GBA core has its memory map and its cartridge layer but no CPU yet, so it
                // cannot run a game. Say so plainly rather than starting a black screen.
                errorMessage = "\(record.title) needs the Game Boy Advance core, which is not finished yet."
                return
            }
            let saveURL = supportDirectory.appendingPathComponent("saves/\(record.system.rawValue)/\(record.id).sav")
            if let saved = try? Data(contentsOf: saveURL) { core.loadBatterySave([UInt8](saved)) }

            let store = SaveStateStore(root: supportDirectory.appendingPathComponent("states"), gameID: record.id)
            stateStore = store
            try? audio.start()
            let session = EmulationSession(core: core, input: input, output: output, audio: audio, frames: mailbox,
                                           gameHash: XXH64.hash(rom), stateStore: store)
            session.onBatterySave = { bytes in
                try? FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(bytes).write(to: saveURL, options: .atomic)
            }
            session.onMessage = { [weak self] text in Task { @MainActor in self?.show(text) } }
            let engine = input
            session.hotkeys = { engine.heldHotkeys() }
            session.currentSlot = currentSlot
            self.session = session
            current = record
            selectedGameID = record.id
            title = record.title
            isPaused = false
            playStart = Date()
            applySettings()
            if resumeAutoSave && store.exists(slot: 0) { session.loadState(slot: 0) }
            session.start()
            DispatchQueue.main.async { [weak self] in self?.gameView?.window?.makeFirstResponder(self?.gameView) }
        } catch {
            errorMessage = "Could not start \(record.title): \(error)"
        }
    }

    func stop() {
        guard let session else { return }
        session.stop()
        self.session = nil
        audio.stop()
        if let record = current {
            library.markPlayed(id: record.id, seconds: playStart.map { Date().timeIntervalSince($0) } ?? 0)
            persistLibrary()
        }
        current = nil
        playStart = nil
        title = "Attic"
        applySettings()
    }

    // MARK: Controls

    func togglePause() {
        guard let session else { return }
        session.setPaused(!session.isPaused)
        isPaused = session.isPaused
    }

    func reset() { session?.requestReset() }

    func saveState() { session?.saveState(slot: currentSlot) }
    func loadState() { session?.loadState(slot: currentSlot) }

    func resumeAutoSave() {
        if isPlaying { session?.loadState(slot: 0) } else if let id = selectedGameID, let record = library.record(id: id) {
            play(record, resumeAutoSave: true)
        }
    }

    func selectSlot(_ slot: Int) {
        currentSlot = min(max(slot, 1), 10)
        session?.currentSlot = currentSlot
        show("Slot \(currentSlot)")
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }
}
