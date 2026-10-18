import AppKit
import ControllerKit
import CoreTestSupport
import PlatformKit
import SwiftUI

@main
struct AtticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controllers = ControllerRegistry()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            exit(Self.runSelfTest())
        }
    }

    var body: some Scene {
        WindowGroup("Attic") {
            ContentView(registry: controllers)
                .frame(minWidth: 480, minHeight: 320)
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
}

struct ContentView: View {
    @ObservedObject var registry: ControllerRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Attic").font(.largeTitle.bold())
            Text("Your library is empty. Game Boy support arrives in milestone M1.")
                .foregroundStyle(.secondary)
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
