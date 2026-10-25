import AppKit
import ControllerKit
import ControllerModel
import EmulatorKit
import GameController
import LibraryKit
import PlatformKit
import SwiftUI

/// The game screen when something is running, otherwise the library.
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: ControllerRegistry

    var body: some View {
        ZStack(alignment: .bottom) {
            if let view = model.gameView, model.isPlaying {
                GameScreen(view: view)
                if model.isPaused {
                    Text("Paused").font(.largeTitle.bold()).padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxHeight: .infinity)
                }
            } else {
                LibraryView(model: model)
            }
            if let toast = model.toast {
                Text(toast).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.toast)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                           set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct GameScreen: NSViewRepresentable {
    let view: GameView

    func makeNSView(context: Context) -> GameView {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: GameView, context: Context) {}
}

// MARK: Library

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var edges = ControllerNavigationEdges()
    private let poll = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.title2.bold())
                Spacer()
                Button("Add Game…") { model.presentAddGamePanel() }
                Button("Add Folder…") { model.presentAddFolderPanel() }
            }
            .padding(16)
            Divider()
            if model.games.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No games yet").font(.title3)
                    Text("Drop Game Boy or Game Boy Color games (or a folder of them) onto this window, or use Add Game / Add Folder.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.games) { game in
                                GameRow(model: model, game: game, selected: model.selectedGameID == game.id)
                                    .id(game.id)
                                    .onTapGesture(count: 2) { model.play(game) }
                                    .onTapGesture { model.selectedGameID = game.id }
                            }
                        }.padding(12)
                    }
                    .onChange(of: model.selectedGameID) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
                }
            }
            Divider()
            Text("Controller: D-pad to choose, A to play, Menu to resume the last automatic save. Keyboard: arrow keys and Return.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .onReceive(poll) { _ in navigate() }
    }

    /// Lets a game controller move through the library (SwiftUI has no built-in gamepad focus on the Mac).
    private func navigate() {
        let held = model.input.gamepad.heldElements()
        let pressed = edges.update(held)
        guard !model.games.isEmpty else { return }
        let ids = model.games.map(\.id)
        let index = ids.firstIndex(of: model.selectedGameID ?? "") ?? 0
        if pressed.contains("Direction Pad Down") { model.selectedGameID = ids[min(index + 1, ids.count - 1)] }
        if pressed.contains("Direction Pad Up") { model.selectedGameID = ids[max(index - 1, 0)] }
        if pressed.contains("Button A"), let game = model.games.first(where: { $0.id == model.selectedGameID }) { model.play(game) }
        if pressed.contains("Button Menu"), model.selectedGameID != nil { model.resumeAutoSave() }
    }
}

struct ControllerNavigationEdges {
    private var previous = Set<String>()
    mutating func update(_ held: Set<String>) -> Set<String> {
        defer { previous = held }
        return held.subtracting(previous)
    }
}

struct GameRow: View {
    @ObservedObject var model: AppModel
    let game: GameRecord
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = model.thumbnail(for: game) {
                    Image(nsImage: image).resizable().interpolation(.none)
                } else {
                    Rectangle().fill(.quaternary).overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary))
                }
            }
            .frame(width: 80, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(game.title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if !game.isAvailable { Text("File not found").font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if model.hasAutoSave(game) {
                Button("Resume") { model.play(game, resumeAutoSave: true) }
            }
            Button("Play") { model.play(game) }.disabled(!game.isAvailable || !model.canPlay(game))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contextMenu {
            Button("Play") { model.play(game) }.disabled(!model.canPlay(game))
            if model.hasAutoSave(game) { Button("Resume from Automatic Save") { model.play(game, resumeAutoSave: true) } }
            Divider()
            Menu("Palette for this game") {
                Button("Use the global setting") { model.updateSettings { $0.perGame[game.id, default: GameSettings()].palette = nil } }
                Button("Gray") { model.updateSettings { $0.perGame[game.id, default: GameSettings()].palette = "gray" } }
                Button("Green") { model.updateSettings { $0.perGame[game.id, default: GameSettings()].palette = "green" } }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
            Button("Remove from Library") { model.removeFromLibrary(game) }
        }
    }

    private var subtitle: String {
        var parts = [systemName]
        if let last = game.lastPlayed {
            parts.append("played " + last.formatted(.relative(presentation: .named)))
            parts.append(Self.duration(game.playSeconds))
        } else {
            parts.append("not played yet")
        }
        return parts.joined(separator: " · ")
    }

    /// The system the game runs on. The Game Boy line has a colour variant, the GBA does not.
    private var systemName: String {
        switch game.system {
        case .gameBoy: game.isColor ? "Game Boy Color" : "Game Boy"
        case .gameBoyAdvance: "Game Boy Advance"
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: ControllerRegistry

    var body: some View {
        TabView {
            VideoSettings(model: model).tabItem { Label("Video", systemImage: "display") }
            AudioSettings(model: model).tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            ControlsSettings(model: model).tabItem { Label("Controls", systemImage: "keyboard") }
            ControllersSettings(model: model, registry: registry).tabItem { Label("Controllers", systemImage: "gamecontroller") }
        }
        .frame(width: 560, height: 460)
        .padding(16)
    }
}

struct VideoSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Scaling", selection: Binding(get: { model.settings.scaling }, set: { v in model.updateSettings { $0.scaling = v } })) {
                Text("Integer (sharpest, black borders)").tag("integer")
                Text("Sharp bilinear (fills the window)").tag("sharpBilinear")
            }
            Picker("Original Game Boy colours", selection: Binding(get: { model.settings.dmgPalette }, set: { v in model.updateSettings { $0.dmgPalette = v } })) {
                Text("Gray").tag("gray")
                Text("Green").tag("green")
            }
            Text("The colour choice applies the next time a game starts. Fullscreen: View > Enter Full Screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AudioSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Slider(value: Binding(get: { Double(model.settings.volume) }, set: { v in model.updateSettings { $0.volume = Float(v) } }),
                   in: 0...1) { Text("Volume") }
            Toggle("Mute", isOn: Binding(get: { model.settings.muted }, set: { v in model.updateSettings { $0.muted = v } }))
        }
    }
}

private let gameButtons: [(String, PadButtons)] = [
    ("Up", .up), ("Down", .down), ("Left", .left), ("Right", .right),
    ("A", .east), ("B", .south), ("Start", .start), ("Select", .select),
]
private let padButtons: [(String, PadButtons)] = [("A", .east), ("B", .south), ("Start", .start), ("Select", .select)]

struct ControlsSettings: View {
    @ObservedObject var model: AppModel
    @State private var waiting: String?
    @State private var keyCapture = KeyCapture()
    @State private var padCapture = ControllerCapture()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard").font(.headline)
                ForEach(gameButtons, id: \.0) { name, button in
                    HStack {
                        Text(name).frame(width: 70, alignment: .leading)
                        Text(keys(for: button)).foregroundStyle(.secondary)
                        Spacer()
                        Button(waiting == "key-\(name)" ? "Press a key…" : "Change") {
                            waiting = "key-\(name)"
                            keyCapture.begin { code in
                                var b = model.input.keyboard.bindings
                                b.rebind(button, toKeyCode: code)
                                model.updateSettings { $0.keyboardOverrides = b.overrides }
                                waiting = nil
                            }
                        }
                    }
                }
                Button("Reset keyboard to defaults") { model.updateSettings { $0.keyboardOverrides = [:] } }
                Divider()
                Text("Controller").font(.headline)
                Text("The d-pad and left stick always move; these are the buttons.").font(.caption).foregroundStyle(.secondary)
                ForEach(padButtons, id: \.0) { name, button in
                    HStack {
                        Text(name).frame(width: 70, alignment: .leading)
                        Text(elements(for: button)).foregroundStyle(.secondary)
                        Spacer()
                        Button(waiting == "pad-\(name)" ? "Press a button…" : "Change") {
                            waiting = "pad-\(name)"
                            padCapture.begin(poll: { model.input.gamepad.heldElements() }) { element in
                                var b = model.input.gamepad.bindings
                                b.rebind(button, toElement: element)
                                model.updateSettings { $0.gamepadOverrides = b.overrides }
                                waiting = nil
                            }
                        }
                    }
                }
                Button("Reset controller to defaults") { model.updateSettings { $0.gamepadOverrides = [:] } }
                Divider()
                Text("Hotkeys").font(.headline)
                Text("Keyboard: F5 save, F8 load, [ and ] change slot, P pause, hold Tab to fast-forward, hold R to rewind.\nController: hold Options (Share / Create / View), then R1 save, L1 load, R2 fast-forward, L2 rewind, Menu pause, D-pad left/right slot.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                StickSettings(model: model, title: "Left stick", side: .left)
                StickSettings(model: model, title: "Right stick", side: .right)
                Divider()
                Text("Turbo").font(.headline)
                Text("A turbo button repeats while it is held: on for a number of frames, then off for the same number.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(turboButtons, id: \.0) { name, button in
                    HStack {
                        Text(name).frame(width: 70, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { model.settings.pipeline.turbo[button]?.period ?? 0 },
                            set: { period in
                                model.updateSettings { settings in
                                    if period == 0 {
                                        settings.pipeline.turbo.removeValue(forKey: button)
                                    } else {
                                        settings.pipeline.turbo[button] = TurboSetting(
                                            period: period,
                                            phaseOffset: settings.pipeline.turbo[button]?.phaseOffset ?? 0)
                                    }
                                }
                            }
                        )) {
                            Text("Off").tag(0)
                            Text("2 frames").tag(2)
                            Text("4 frames").tag(4)
                            Text("6 frames").tag(6)
                            Text("8 frames").tag(8)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        if (model.settings.pipeline.turbo[button]?.period ?? 0) > 0 {
                            Picker("", selection: Binding(
                                get: { model.settings.pipeline.turbo[button]?.phaseOffset ?? 0 },
                                set: { offset in
                                    model.updateSettings { settings in
                                        settings.pipeline.turbo[button]?.phaseOffset = offset
                                    }
                                }
                            )) {
                                Text("No offset").tag(0)
                                Text("Offset 1").tag(1)
                                Text("Offset 2").tag(2)
                                Text("Offset 3").tag(3)
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }

    /// The buttons a turbo setting can be given, in the order they are shown.
    private var turboButtons: [(String, PadButtons)] {
        [("A", .east), ("B", .south), ("X", .west), ("Y", .north),
         ("L1", .l1), ("R1", .r1), ("L2", .l2), ("R2", .r2),
         ("Start", .start), ("Select", .select)]
    }

    private func keys(for button: PadButtons) -> String {
        let codes = model.input.keyboard.bindings.map.filter { $0.value == button }.keys.sorted()
        return codes.isEmpty ? "—" : codes.map { KeyNames.name(for: $0) }.joined(separator: ", ")
    }

    private func elements(for button: PadButtons) -> String {
        let names = model.input.gamepad.bindings.map.filter { $0.value == button }.keys.sorted()
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }
}

// MARK: Controllers

/// The deadzone and curve editor for one stick. The plan asks for a live scatter plot; the
/// plot here is a drawn curve of the stick's travel, which is what the setting changes.
struct StickSettings: View {
    @ObservedObject var model: AppModel
    let title: String
    /// Which stick this edits.
    let side: Side

    enum Side {
        case left, right

        var config: (PipelineSettings) -> StickConfig {
            switch self {
            case .left: { $0.leftStick }
            case .right: { $0.rightStick }
            }
        }

        var curve: (PipelineSettings) -> ResponseCurve {
            switch self {
            case .left: { $0.leftCurve }
            case .right: { $0.rightCurve }
            }
        }

        func setConfig(_ value: StickConfig, on settings: inout PipelineSettings) {
            switch self {
            case .left: settings.leftStick = value
            case .right: settings.rightStick = value
            }
        }

        func setCurve(_ value: ResponseCurve, on settings: inout PipelineSettings) {
            switch self {
            case .left: settings.leftCurve = value
            case .right: settings.rightCurve = value
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                Text("Inner deadzone").frame(width: 130, alignment: .leading)
                Slider(value: innerBinding, in: 0...0.5)
                Text(String(format: "%.2f", config.innerDeadzone))
                    .frame(width: 40, alignment: .trailing).monospacedDigit()
            }
            HStack {
                Text("Outer deadzone").frame(width: 130, alignment: .leading)
                Slider(value: outerBinding, in: 0.5...1)
                Text(String(format: "%.2f", config.outerDeadzone))
                    .frame(width: 40, alignment: .trailing).monospacedDigit()
            }
            HStack {
                Text("Curve").frame(width: 130, alignment: .leading)
                Picker("", selection: curveBinding) {
                    ForEach(ResponseCurve.allCases, id: \.self) { curve in
                        Text(curve.label).tag(curve)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            TravelPlot(curve: curve, inner: config.innerDeadzone, outer: config.outerDeadzone)
                .frame(height: 90)
        }
    }

    private var config: StickConfig { side.config(model.settings.pipeline) }
    private var curve: ResponseCurve { side.curve(model.settings.pipeline) }

    private var innerBinding: Binding<Double> {
        Binding(get: { Double(config.innerDeadzone) },
                 set: { value in
                     model.updateSettings { settings in
                         var updated = side.config(settings.pipeline)
                         updated.innerDeadzone = Float(value)
                         side.setConfig(updated, on: &settings.pipeline)
                     }
                 })
    }

    private var outerBinding: Binding<Double> {
        Binding(get: { Double(config.outerDeadzone) },
                 set: { value in
                     model.updateSettings { settings in
                         var updated = side.config(settings.pipeline)
                         updated.outerDeadzone = Float(value)
                         side.setConfig(updated, on: &settings.pipeline)
                     }
                 })
    }

    private var curveBinding: Binding<ResponseCurve> {
        Binding(get: { curve },
                 set: { value in model.updateSettings { side.setCurve(value, on: &$0.pipeline) } })
    }
}

/// Draws how the stick's travel is shaped: the horizontal axis is the raw travel, the vertical
/// axis is what the game sees. The deadzone shows as the flat part at the left.
struct TravelPlot: View {
    let curve: ResponseCurve
    let inner: Float
    let outer: Float

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let steps = 60
                for step in 0...steps {
                    let raw = Float(step) / Float(steps)
                    let mapped = deadzone(raw)
                    let x = CGFloat(raw) * geometry.size.width
                    let y = geometry.size.height - CGFloat(mapped) * geometry.size.height
                    if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.tint, lineWidth: 2)
        }
    }

    /// The same shaping the pipeline applies, so the plot cannot drift from the behaviour.
    private func deadzone(_ raw: Float) -> Float {
        let magnitude = min(max(raw - inner, 0) / max(outer - inner, 0.0001), 1)
        return curve.apply(magnitude)
    }
}

struct ControllersSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: ControllerRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if registry.controllers.isEmpty {
                Text("No controller connected. Xbox, DualShock 4 and DualSense controllers work over Bluetooth or USB.")
                    .foregroundStyle(.secondary)
            }
            ForEach(registry.controllers) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name).font(.headline)
                    Text("\(c.family.rawValue) · \(c.summary)").font(.caption).foregroundStyle(.secondary)
                    if let level = c.batteryLevel { ProgressView("Battery", value: Double(level)).frame(maxWidth: 220) }
                }
            }
            Divider()
            ControllerTester(model: model)
            Spacer()
        }
    }
}

/// Live view of what the first controller is doing: which buttons are down and where the sticks are.
struct ControllerTester: View {
    @ObservedObject var model: AppModel
    @State private var held = Set<String>()
    @State private var left: (x: Float, y: Float) = (0, 0)
    @State private var right: (x: Float, y: Float) = (0, 0)
    private let poll = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private static let names = [
        "Button A", "Button B", "Button X", "Button Y", "Left Shoulder", "Right Shoulder", "Left Trigger", "Right Trigger",
        "Button Menu", "Button Options", "Left Thumbstick Button", "Right Thumbstick Button",
        "Direction Pad Up", "Direction Pad Down", "Direction Pad Left", "Direction Pad Right",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tester").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Self.names, id: \.self) { name in
                    Text(name.replacingOccurrences(of: "Direction Pad ", with: "D-pad ").replacingOccurrences(of: "Button ", with: ""))
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6).fill(held.contains(name) ? Color.accentColor : Color.gray.opacity(0.2)))
                        .foregroundStyle(held.contains(name) ? Color.white : Color.primary)
                }
            }
            HStack(spacing: 24) {
                StickView(title: "Left stick", x: left.x, y: left.y)
                StickView(title: "Right stick", x: right.x, y: right.y)
            }
        }
        .onReceive(poll) { _ in
            held = model.input.gamepad.heldElements()
            left = model.input.gamepad.leftStick
            right = model.input.gamepad.rightStick
        }
    }
}

struct StickView: View {
    let title: String
    let x: Float
    let y: Float

    var body: some View {
        VStack {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1)
                Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                    .offset(x: CGFloat(x) * 24, y: CGFloat(-y) * 24)
            }.frame(width: 60, height: 60)
            Text(title).font(.caption)
        }
    }
}
