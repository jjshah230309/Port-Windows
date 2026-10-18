import CoreTestSupport
import Foundation

// Headless ROM test runner. In M0 it only validates manifests; the cores that execute them arrive from M1 on.
var directory = URL(fileURLWithPath: "Tests/Manifests")
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    if arg == "--manifests", let value = args.popFirst() { directory = URL(fileURLWithPath: value) }
}

// Ad-hoc run: rom-test --gb <rom> [--frames N] [--model dmg|cgb]
if let i = CommandLine.arguments.firstIndex(of: "--gb"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    var frames = 3_000
    if let j = CommandLine.arguments.firstIndex(of: "--frames"), j + 1 < CommandLine.arguments.count {
        frames = Int(CommandLine.arguments[j + 1]) ?? frames
    }
    var model = "auto"
    if let j = CommandLine.arguments.firstIndex(of: "--model"), j + 1 < CommandLine.arguments.count {
        model = CommandLine.arguments[j + 1]
    }
    do {
        let rom = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let r = try HeadlessGB.run(rom: rom, maxFrames: frames, model: model)
        print("frames=\(r.frames) verdict=\(r.passedByText.map { $0 ? "PASSED" : "FAILED" } ?? "none") hash=\(String(r.frameHash, radix: 16))")
        print(r.serial)
        if let j = CommandLine.arguments.firstIndex(of: "--ppm"), j + 1 < CommandLine.arguments.count {
            var out = Array("P6\n160 144\n255\n".utf8)
            for px in r.pixels { out += [UInt8((px >> 16) & 0xFF), UInt8((px >> 8) & 0xFF), UInt8(px & 0xFF)] }
            try Data(out).write(to: URL(fileURLWithPath: CommandLine.arguments[j + 1]))
        }
        exit(r.passedByText == false ? 1 : 0)
    } catch {
        print("error: \(error)")
        exit(2)
    }
}

do {
    let manifests = try Manifest.loadAll(in: directory)
    let total = manifests.reduce(0) { $0 + $1.entries.count }
    print("rom-test: \(manifests.count) manifest(s), \(total) entr(ies); no emulator cores are runnable yet (M0).")
} catch {
    print("rom-test: could not read manifests in \(directory.path): \(error)")
    exit(1)
}
