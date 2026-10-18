# Attic (working name)

A native-Swift Mac app for playing games **you own**: Windows PC games (through Wine), PlayStation 1 discs, and Game Boy / Game Boy Color / Game Boy Advance cartridges. It is built with Swift Package Manager and the Command Line Tools only (no Xcode), and has full support for Xbox, DualShock 4, DualSense and DualSense Edge controllers.

> **Status: milestone M0 (scaffolding).** The package layout, controller model, build script, app shell and CI exist. No emulator runs games yet. The full roadmap is in [docs/PLAN.md](docs/PLAN.md).

## What works today
* `swift build` / `swift test` for the pure-Swift modules (Linux and macOS).
* A macOS app shell (`Attic.app`) that lists connected controllers and can self-test its Metal shader compiler.
* The controller input pipeline (deadzones, trigger hysteresis, SOCD), Sony report checksums, input traces and save-state container, all unit tested.

## Build
```bash
swift build                      # everything for your OS
swift test                       # unit tests
swift run core-selftest          # framework-free checks (works with only the Command Line Tools)
swift run controller-dump        # macOS: print what every connected controller exposes
scripts/build-app.sh             # macOS: dist/Attic.app (ad-hoc signed) + zip + dmg
dist/Attic.app/Contents/MacOS/Attic --self-test
```
Requires an Apple-silicon Mac on macOS 15+ for the app, and Swift 6.1+. The pure-Swift modules also build on Linux.

## Install an unsigned build
Builds are ad-hoc signed, not notarised. After copying `Attic.app` to Applications, either open **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Attic.app`.

## Legal
Attic ships **no** games, BIOS files, keys or Apple/Microsoft components. You supply your own dumps. See [docs/LEGAL.md](docs/LEGAL.md) and [docs/DUMPING.md](docs/DUMPING.md).

## License
[MIT](LICENSE)
