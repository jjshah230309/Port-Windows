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

// Full run: rom-test --all [--roms .cache/test-roms] [--manifests Tests/Manifests] [--md report.md]
// Runs every manifest entry plus the Mooneye suite; exits 1 only on regressions (an expected pass that failed).
if CommandLine.arguments.contains("--all") {
    func value(_ flag: String, _ fallback: String) -> String {
        if let j = CommandLine.arguments.firstIndex(of: flag), j + 1 < CommandLine.arguments.count { return CommandLine.arguments[j + 1] }
        return fallback
    }
    let romRoot = URL(fileURLWithPath: value("--roms", ".cache/test-roms"))
    let manifestDir = URL(fileURLWithPath: value("--manifests", "Tests/Manifests"))
    var report = "# ROM test report\n\n"
    var regressions = 0
    var all: [(String, [SuiteResult])] = []
    if let manifests = try? Manifest.loadAll(in: manifestDir) {
        for m in manifests where m.system == "gb" { all.append(("Manifest (\(m.system))", ROMSuite.runManifest(m, romRoot: romRoot))) }
    }
    let mooneyeRoot = romRoot.appendingPathComponent("mooneye/mts-20240926-1737-443f6e1")
    if FileManager.default.fileExists(atPath: mooneyeRoot.path) {
        let known = ROMSuite.loadKnownFail(manifestDir.appendingPathComponent("mooneye-known-fail.txt"))
        let filter = value("--filter", "")
        all.append(("Mooneye test suite", ROMSuite.runMooneye(root: mooneyeRoot, knownFail: known, filter: filter)))
    } else {
        print("Mooneye suite not found under \(romRoot.path); run scripts/fetch-test-roms.sh")
    }
    for (title, results) in all {
        for r in results {
            let tag: String
            switch r.outcome {
            case .pass: tag = r.isImprovement ? "NEW-PASS" : "PASS"
            case .fail: tag = r.expected == "known-fail" ? "known-fail" : "FAIL"
            case .skipped: tag = "SKIP"
            }
            if tag != "PASS" { print("\(tag.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.name)  \(r.detail)") }
        }
        regressions += results.filter(\.isRegression).count
        let md = ROMSuite.markdown(title, results)
        print(md)
        report += md + "\n"
    }
    let mdPath = value("--md", "")
    if !mdPath.isEmpty { try? report.write(toFile: mdPath, atomically: true, encoding: .utf8) }
    exit(regressions == 0 ? 0 : 1)
}

do {
    let manifests = try Manifest.loadAll(in: directory)
    let total = manifests.reduce(0) { $0 + $1.entries.count }
    print("rom-test: \(manifests.count) manifest(s), \(total) entr(ies); no emulator cores are runnable yet (M0).")
} catch {
    print("rom-test: could not read manifests in \(directory.path): \(error)")
    exit(1)
}
