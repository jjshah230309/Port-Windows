import ControllerModel
import EmulatorKit
import Foundation

/// Per-game overrides; nil means "use the global setting".
public struct GameSettings: Codable, Equatable, Sendable {
    public var palette: String?
    public var scaling: String?
    public init(palette: String? = nil, scaling: String? = nil) {
        self.palette = palette
        self.scaling = scaling
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// "integer" or "sharpBilinear".
    public var scaling = "integer"
    /// "gray" or "green": the four shades used for original Game Boy games.
    public var dmgPalette = "gray"
    public var volume: Float = 1.0
    public var muted = false
    /// Keyboard remaps: hardware key code (as text) -> PadButtons raw value. Missing entries use the defaults.
    public var keyboardOverrides: [String: UInt64] = [:]
    /// Controller remaps: Apple element name (such as "Button A") -> PadButtons raw value.
    public var gamepadOverrides: [String: UInt64] = [:]
    /// The deadzones, curves, trigger thresholds and turbo buttons the input pipeline uses.
    public var pipeline = PipelineSettings()
    public var perGame: [String: GameSettings] = [:]

    public init() {}

    public func effectivePalette(for gameID: String) -> String { perGame[gameID]?.palette ?? dmgPalette }
    public func effectiveScaling(for gameID: String) -> String { perGame[gameID]?.scaling ?? scaling }
}

/// Loads and saves `AppSettings` as JSON. A damaged file is set aside and defaults are used.
public final class SettingsStore {
    private let fileURL: URL
    public var settings: AppSettings

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
                settings = decoded
            } else {
                settings = AppSettings()
                try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("corrupt"))
            }
        } else {
            settings = AppSettings()
        }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
