import AppKit
import ControllerKit
import EmulatorKit
import Foundation
import GBCore
import PlatformKit
import UniformTypeIdentifiers

/// Owns the running game: the core, the emulation thread, audio, video and input.
@MainActor
final class AppModel: ObservableObject {
    @Published var title = "Attic"
    @Published var gameName: String?
    @Published var errorMessage: String?
    @Published var isPaused = false

    let mailbox = FrameMailbox()
    let input = HostInput()
    let output = HostOutput()
    let audio = AudioOutput()
    private(set) var gameView: GameView?
    private var session: EmulationSession?
    private var launchHandled = false

    var isPlaying: Bool { session != nil }

    init() {
        gameView = GameView(mailbox: mailbox)
        gameView?.keyHandler = { [weak self] event, down in self?.handleKey(event, down: down) }
    }

    // MARK: Opening games

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["gb", "gbc"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Game Boy or Game Boy Color game you own"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// Handles `Attic --open <path>` once, after the window exists.
    func openFromArguments() {
        guard !launchHandled else { return }
        launchHandled = true
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            open(url: URL(fileURLWithPath: args[i + 1]))
        }
    }

    func open(url: URL) {
        stop()
        errorMessage = nil
        do {
            let rom = [UInt8](try Data(contentsOf: url))
            let core = try GameBoyCore(media: .rom(rom), firmware: FirmwareSet(), options: CoreOptions(), clock: SystemClock())
            let saveURL = Self.saveURL(for: url)
            if let saved = try? Data(contentsOf: saveURL) { core.loadBatterySave([UInt8](saved)) }

            try? audio.start()
            let session = EmulationSession(core: core, input: input, output: output, audio: audio, frames: mailbox)
            session.onBatterySave = { bytes in
                try? FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(bytes).write(to: saveURL, options: .atomic)
            }
            self.session = session
            gameName = core.title.isEmpty ? url.deletingPathExtension().lastPathComponent : core.title
            title = gameName ?? "Attic"
            isPaused = false
            session.start()
            DispatchQueue.main.async { [weak self] in self?.gameView?.window?.makeFirstResponder(self?.gameView) }
        } catch let error as GameBoyError {
            switch error {
            case .invalidROM(let why): errorMessage = "This file is not a valid Game Boy game (\(why))."
            case .unsupportedMapper(let type): errorMessage = String(format: "This cartridge type ($%02X) is not supported yet.", type)
            }
        } catch {
            errorMessage = "Could not open the file: \(error.localizedDescription)"
        }
    }

    func stop() {
        session?.stop()
        session = nil
        audio.stop()
        gameName = nil
        title = "Attic"
    }

    // MARK: Controls

    func togglePause() {
        guard let session else { return }
        session.setPaused(!session.isPaused)
        isPaused = session.isPaused
    }

    func reset() { session?.requestReset() }

    private func handleKey(_ event: NSEvent, down: Bool) {
        switch event.keyCode {
        case 48:                                     // Tab: hold for fast-forward
            session?.setFastForward(down)
        case 35 where down && !event.isARepeat:      // P: pause
            togglePause()
        default:
            input.keyboard.handle(keyCode: event.keyCode, down: down)
        }
    }

    private static func saveURL(for rom: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Attic/saves/gb", isDirectory: true)
            .appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".sav")
    }
}
