// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Release-only flags for the emulator hot loops. Debug builds keep every safety check.
let hot: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]

// SwiftPM does not put `Testing.framework` on the framework search path when the active
// developer directory is the Command Line Tools, so `import Testing` fails to compile and the
// test bundle fails to link. Add the directory explicitly when it exists. Under a full Xcode
// install this is a no-op, because SwiftPM already searches that path.
let testingFrameworkRoot: String? = {
    let roots = [
        "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "/Applications/Xcode.app/Contents/Developer/Library/Frameworks",
    ]
    return roots.first { FileManager.default.fileExists(atPath: $0 + "/Testing.framework") }
}()

let testingFrameworks: [SwiftSetting] = testingFrameworkRoot.map { [.unsafeFlags(["-F", $0])] } ?? []

// `Testing.framework` itself links `lib_TestingInterop.dylib`, which the Command Line Tools
// ship outside the frameworks directory.
let testingInteropRoot: String? = {
    let roots = [
        "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
        "/Applications/Xcode.app/Contents/Developer/usr/lib",
    ]
    return roots.first { FileManager.default.fileExists(atPath: $0 + "/lib_TestingInterop.dylib") }
}()

let testingLinker: [LinkerSetting] = {
    guard let frameworkRoot = testingFrameworkRoot else { return [] }
    // `-F` finds the framework at link time; the rpath lets dyld find it again at run time,
    // because the test bundle is loaded by SwiftPM's testing helper rather than by the app.
    var flags = ["-F", frameworkRoot]
    flags += ["-Xlinker", "-rpath", "-Xlinker", frameworkRoot]
    if let interopRoot = testingInteropRoot {
        flags += ["-Xlinker", "-rpath", "-Xlinker", interopRoot]
    }
    flags += ["-Xlinker", "-framework", "-Xlinker", "Testing"]
    return [.unsafeFlags(flags)]
}()

/// A test target that can import `Testing` under the Command Line Tools.
func testTarget(_ name: String, dependencies: [Target.Dependency]) -> Target {
    .testTarget(name: name, dependencies: dependencies,
                swiftSettings: testingFrameworks, linkerSettings: testingLinker)
}

var targets: [Target] = [
    // Shared contracts and utilities (standard library only, so they build and test on Linux).
    .target(name: "EmulatorKit"),
    .target(name: "EmuSupport"),
    .target(name: "DiscFormats", dependencies: ["EmulatorKit", "EmuSupport"]),
    .target(name: "PSG", swiftSettings: hot),
    .target(name: "WinFormats"),

    // Emulator cores.
    .target(name: "GBCore", dependencies: ["EmulatorKit", "EmuSupport", "PSG"], swiftSettings: hot),
    .target(name: "GBACore", dependencies: ["EmulatorKit", "EmuSupport", "PSG"], swiftSettings: hot),
    .target(name: "PS1Core", dependencies: ["EmulatorKit", "EmuSupport", "DiscFormats"], swiftSettings: hot),

    // Library, save-state slots and settings (Foundation only).
    .target(name: "LibraryKit", dependencies: ["EmulatorKit", "EmuSupport"]),

    // Controller logic that needs no Apple frameworks.
    .target(name: "ControllerModel", dependencies: ["EmulatorKit", "EmuSupport"]),

    // Headless test support and command-line tools.
    .target(name: "CoreTestSupport", dependencies: [
        "EmulatorKit", "EmuSupport", "ControllerModel", "GBCore", "GBACore", "PS1Core",
    ]),
    .executableTarget(name: "rom-test", dependencies: ["CoreTestSupport", "EmuSupport"]),
    .executableTarget(name: "emu-bench", dependencies: ["CoreTestSupport"]),
    .executableTarget(name: "core-selftest", dependencies: ["CoreTestSupport"]),

    testTarget("EmuSupportTests", dependencies: ["EmuSupport"]),
    testTarget("EmulatorKitTests", dependencies: ["EmulatorKit"]),
    testTarget("ControllerModelTests", dependencies: ["ControllerModel", "EmulatorKit", "EmuSupport"]),
    testTarget("CoreTestSupportTests", dependencies: ["CoreTestSupport"]),
    testTarget("LibraryKitTests", dependencies: ["LibraryKit", "EmulatorKit", "EmuSupport"]),
    testTarget("GBCoreTests", dependencies: ["GBCore", "EmulatorKit", "EmuSupport", "CoreTestSupport"]),
]

#if os(macOS)
targets += [
    .target(name: "PlatformKit", dependencies: ["EmulatorKit", "ControllerModel", "LibraryKit", "EmuSupport"]),
    .target(name: "ControllerKit", dependencies: ["ControllerModel", "EmulatorKit", "LibraryKit"]),
    .target(name: "WindowsKit", dependencies: ["WinFormats", "EmuSupport"]),
    .executableTarget(
        name: "Attic",
        dependencies: ["PlatformKit", "ControllerKit", "WindowsKit", "CoreTestSupport", "GBCore", "EmulatorKit", "ControllerModel", "LibraryKit", "EmuSupport"],
        path: "Sources/AtticApp"
    ),
    .executableTarget(name: "controller-dump", dependencies: ["ControllerKit"]),
]
#endif

let package = Package(
    name: "Attic",
    platforms: [.macOS(.v15)],
    targets: targets
)
