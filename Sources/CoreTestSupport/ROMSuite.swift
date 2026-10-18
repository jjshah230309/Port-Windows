import Foundation

public enum SuiteOutcome: Equatable { case pass, fail, skipped(String) }

public struct SuiteResult {
    public var name: String
    public var outcome: SuiteOutcome
    public var expected: String          // "pass" or "known-fail"
    public var detail: String

    /// True when this result should fail the run: an expected pass that failed.
    public var isRegression: Bool { outcome == .fail && expected == "pass" }
    /// True when a known-fail test now passes (good news worth reporting).
    public var isImprovement: Bool { outcome == .pass && expected == "known-fail" }
}

/// Runs manifest entries and the Mooneye suite against the Game Boy core.
public enum ROMSuite {
    public static func runManifest(_ manifest: Manifest, romRoot: URL) -> [SuiteResult] {
        manifest.entries.map { entry in
            let url = romRoot.appendingPathComponent(entry.path)
            guard let data = try? Data(contentsOf: url) else {
                return SuiteResult(name: entry.name, outcome: .skipped("ROM not found: \(entry.path)"),
                                   expected: entry.expected, detail: "")
            }
            let rom = [UInt8](data)
            do {
                switch entry.criterion {
                case "mooneye":
                    let r = try HeadlessGB.runMooneye(rom: rom, model: entry.model ?? "dmg", maxFrames: entry.maxFrames)
                    return SuiteResult(name: entry.name, outcome: r == .passed ? .pass : .fail, expected: entry.expected, detail: "\(r)")
                case "frameHash":
                    let r = try HeadlessGB.run(rom: rom, maxFrames: entry.maxFrames, model: entry.model ?? "auto", stopOnSerialVerdict: false)
                    let hash = String(r.frameHash, radix: 16)
                    return SuiteResult(name: entry.name, outcome: hash == entry.expectedHash ? .pass : .fail,
                                       expected: entry.expected, detail: "hash \(hash), expected \(entry.expectedHash ?? "?")")
                default:   // "serial" and "cartram" both end with a Passed/Failed verdict
                    let r = try HeadlessGB.run(rom: rom, maxFrames: entry.maxFrames, model: entry.model ?? "auto")
                    return SuiteResult(name: entry.name, outcome: r.passedByText == true ? .pass : .fail, expected: entry.expected,
                                       detail: r.passedByText.map { $0 ? "Passed" : "Failed" } ?? "no verdict in \(r.frames) frames")
                }
            } catch {
                return SuiteResult(name: entry.name, outcome: .fail, expected: entry.expected, detail: "error: \(error)")
            }
        }
    }

    /// Mooneye model selection from the file name suffix (`-dmgABC`, `-cgb`, `-S`, ...). Returns nil to skip.
    static func mooneyeModel(name: String) -> String? {
        guard name.contains("-"), let suffix = name.split(separator: "-").last.map(String.init) else { return "dmg" }
        let isModelSuffix = suffix.hasPrefix("dmg") || suffix.hasPrefix("cgb") || suffix.hasPrefix("mgb") || suffix.hasPrefix("sgb")
            || suffix == "S" || suffix == "A" || suffix == "C" || suffix.hasPrefix("agb") || suffix.hasPrefix("ags") || suffix == "GS"
        if !isModelSuffix { return "dmg" }
        if suffix.hasPrefix("cgb") { return "cgb" }
        if suffix.hasPrefix("dmg") && !suffix.hasPrefix("dmg0") { return "dmg" }
        if suffix == "GS" { return "dmg" }
        return nil
    }

    public static func runMooneye(root: URL, knownFail: Set<String>, filter: String = "") -> [SuiteResult] {
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "gb" || u.pathExtension == "gbc" { files.append(u) }
        }
        files.sort { $0.path < $1.path }
        var results: [SuiteResult] = []
        for u in files where filter.isEmpty || u.path.contains(filter) {
            let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
            if rel.contains("manual-only/") || rel.contains("utils/") { continue }
            let name = u.deletingPathExtension().lastPathComponent
            let expected = knownFail.contains(rel) ? "known-fail" : "pass"
            guard let model = mooneyeModel(name: name) else {
                results.append(SuiteResult(name: rel, outcome: .skipped("other hardware model"), expected: expected, detail: ""))
                continue
            }
            do {
                let rom = [UInt8](try Data(contentsOf: u))
                let r = try HeadlessGB.runMooneye(rom: rom, model: model)
                results.append(SuiteResult(name: rel, outcome: r == .passed ? .pass : .fail, expected: expected, detail: "\(r) [\(model)]"))
            } catch {
                results.append(SuiteResult(name: rel, outcome: .skipped("\(error)"), expected: expected, detail: ""))
            }
        }
        return results
    }

    public static func loadKnownFail(_ url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// Markdown report with a summary line and one row per non-passing or surprising result.
    public static func markdown(_ title: String, _ results: [SuiteResult]) -> String {
        let pass = results.filter { $0.outcome == .pass }.count
        let skipped = results.filter { if case .skipped = $0.outcome { return true } else { return false } }.count
        let regressions = results.filter(\.isRegression)
        let improvements = results.filter(\.isImprovement)
        var out = "## \(title)\n\n\(pass) passed, \(regressions.count) regressed, \(improvements.count) newly passing, \(skipped) skipped, "
        out += "\(results.count) total\n\n"
        for r in regressions { out += "- REGRESSION: \(r.name) (\(r.detail))\n" }
        for r in improvements { out += "- now passing, remove from the known-fail list: \(r.name)\n" }
        return out
    }
}
