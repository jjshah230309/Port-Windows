import Foundation

/// One entry of a `Tests/Manifests/*.json` file: a ROM, how to run it, and what counts as passing.
public struct ManifestEntry: Codable, Equatable {
    public var name: String
    public var path: String
    public var sha256: String?
    public var maxFrames: Int
    public var criterion: String
    public var expected: String   // "pass" or "known-fail"
}

public struct Manifest: Codable, Equatable {
    public var system: String
    public var entries: [ManifestEntry]

    public static func load(from url: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    public static func loadAll(in directory: URL) throws -> [Manifest] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(load(from:))
    }
}
