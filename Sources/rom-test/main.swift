import CoreTestSupport
import Foundation

// Headless ROM test runner. In M0 it only validates manifests; the cores that execute them arrive from M1 on.
var directory = URL(fileURLWithPath: "Tests/Manifests")
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    if arg == "--manifests", let value = args.popFirst() { directory = URL(fileURLWithPath: value) }
}

do {
    let manifests = try Manifest.loadAll(in: directory)
    let total = manifests.reduce(0) { $0 + $1.entries.count }
    print("rom-test: \(manifests.count) manifest(s), \(total) entr(ies); no emulator cores are runnable yet (M0).")
} catch {
    print("rom-test: could not read manifests in \(directory.path): \(error)")
    exit(1)
}
