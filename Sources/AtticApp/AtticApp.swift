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
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in model.handleDrop(url: url) } }
                        }
                    }
                    return !providers.isEmpty
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { model.presentAddGamePanel() }.keyboardShortcut("o")
                Button("Add Folder…") { model.presentAddFolderPanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Game") {
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }.disabled(!model.isPlaying)
                Button("Reset") { model.reset() }.keyboardShortcut("r").disabled(!model.isPlaying)
                Divider()
                Button("Save State") { model.saveState() }.keyboardShortcut("s").disabled(!model.isPlaying)
                Button("Load State") { model.loadState() }.keyboardShortcut("l").disabled(!model.isPlaying)
                Button("Resume Automatic Save") { model.resumeAutoSave() }
                Menu("Save Slot") {
                    ForEach(1...10, id: \.self) { slot in
                        Button((model.currentSlot == slot ? "✓ " : "") + "Slot \(slot)") { model.selectSlot(slot) }
                    }
                }
                Divider()
                Button("Close Game") { model.stop() }.keyboardShortcut("w").disabled(!model.isPlaying)
            }
            CommandGroup(after: .toolbar) {
                Button("Integer Scaling") { model.updateSettings { $0.scaling = "integer" } }
                Button("Sharp Bilinear Scaling") { model.updateSettings { $0.scaling = "sharpBilinear" } }
            }
        }
        Settings {
            SettingsView(model: model, registry: controllers)
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
