import AppKit
import ControllerKit
import CoreTestSupport
import PlatformKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AtticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controllers = ControllerRegistry()
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            exit(Self.runSelfTest())
        }
    }

    var body: some Scene {
        WindowGroup("Attic") {
            RootView(model: model, registry: controllers)
                .frame(minWidth: 480, minHeight: 432)
                .navigationTitle(model.title)
                .onAppear { model.openFromArguments() }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.open(url: url) } }
                    }
                    return true
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Game…") { model.presentOpenPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Game") {
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }.disabled(!model.isPlaying)
                Button("Reset") { model.reset() }.keyboardShortcut("r").disabled(!model.isPlaying)
                Button("Close Game") { model.stop() }.keyboardShortcut("w").disabled(!model.isPlaying)
            }
        }
    }

    /// Runs the framework-free checks plus the runtime Metal shader test. Used by CI on the packaged app.
    private static func runSelfTest() -> Int32 {
        var failed = false
        let failures = SelfTest.run()
        if failures.isEmpty {
            print("self-test: core checks passed")
        } else {
            failed = true
            for f in failures { print("self-test FAIL: \(f)") }
        }
        switch ShaderSelfTest.run() {
        case .passed(let note): print("self-test: shader \(note)")
        case .skipped(let note): print("self-test: shader skipped (\(note))")
        case .failed(let note):
            failed = true
            print("self-test FAIL: shader \(note)")
        }
        return failed ? 1 : 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched unbundled (`swift run Attic`), harmless inside the .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The game screen when something is running, otherwise the (still empty) library.
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: ControllerRegistry

    var body: some View {
        ZStack {
            if let view = model.gameView, model.isPlaying {
                GameScreen(view: view)
                if model.isPaused {
                    Text("Paused").font(.largeTitle.bold()).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Library(model: model, registry: registry)
            }
        }
        .alert("Could not open the game", isPresented: Binding(get: { model.errorMessage != nil },
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

struct Library: View {
    @ObservedObject var model: AppModel
    @ObservedObject var registry: ControllerRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attic").font(.largeTitle.bold())
            Text("Drop a Game Boy or Game Boy Color game here, or open one. Keys: arrows, X = A, Z = B, Return = Start, Delete = Select, Tab = fast-forward, P = pause.")
                .foregroundStyle(.secondary)
            Button("Open Game…") { model.presentOpenPanel() }
            Divider()
            Text("Controllers").font(.headline)
            if registry.controllers.isEmpty {
                Text("No controller connected.").foregroundStyle(.secondary)
            } else {
                ForEach(registry.controllers) { c in
                    VStack(alignment: .leading) {
                        Text("\(c.name)  (\(c.family.rawValue))")
                        Text(c.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }
}
