// swift-tools-version: 6.0
import PackageDescription

// Release-only flags for the emulator hot loops. Debug builds keep every safety check.
let hot: [SwiftSetting] = [
    .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]

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

    .testTarget(name: "EmuSupportTests", dependencies: ["EmuSupport"]),
    .testTarget(name: "EmulatorKitTests", dependencies: ["EmulatorKit"]),
    .testTarget(name: "ControllerModelTests", dependencies: ["ControllerModel", "EmulatorKit", "EmuSupport"]),
    .testTarget(name: "CoreTestSupportTests", dependencies: ["CoreTestSupport"]),
    .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit", "EmulatorKit", "EmuSupport"]),
    .testTarget(name: "GBCoreTests", dependencies: ["GBCore", "EmulatorKit", "EmuSupport", "CoreTestSupport"]),
]

#if os(macOS)
targets += [
    .target(name: "PlatformKit", dependencies: ["EmulatorKit"]),
    .target(name: "ControllerKit", dependencies: ["ControllerModel", "EmulatorKit"]),
    .target(name: "WindowsKit", dependencies: ["WinFormats", "EmuSupport"]),
    .executableTarget(
        name: "Attic",
        dependencies: ["PlatformKit", "ControllerKit", "WindowsKit", "CoreTestSupport", "GBCore", "EmulatorKit"],
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
