# Attic (working name)

A native-Swift Mac app for playing games **you own**: Windows PC games (through Wine), PlayStation 1 discs, and Game Boy / Game Boy Color / Game Boy Advance cartridges. It is built with Swift Package Manager and the Command Line Tools only (no Xcode), and has full support for Xbox, DualShock 4, DualSense and DualSense Edge controllers.

> **Status: milestone M1 (Game Boy / Game Boy Color).** A from-scratch Swift Game Boy core runs, with a macOS player (Metal video, audio, keyboard and controller input, battery saves). GBA, PS1 and Windows are later milestones; see [docs/PLAN.md](docs/PLAN.md).

## What works today
* **Game Boy and Game Boy Color core** (no boot ROM needed): CPU with M-cycle timing, timers, PPU (DMG and CGB colour), sound, MBC1/2/3 (with clock)/5 (with rumble), battery saves, save states.
* **Accuracy checks:** Blargg `cpu_instrs`, `instr_timing`, `mem_timing`, `mem_timing-2` pass; dmg-acid2 and cgb-acid2 match their reference images; 81 Mooneye tests pass (the 17 known failures are listed with reasons in `Tests/Manifests/mooneye-known-fail.txt`). See [docs/TESTING.md](docs/TESTING.md).
* **macOS player:** `Attic --open game.gb`, File > Open, or drag a game onto the window. Keys: arrows, X = A, Z = B, Return = Start, Delete = Select, Tab = fast-forward, P = pause. Game controllers (Xbox, DualShock 4, DualSense) work and rumble on rumble cartridges. **The player has been compiled and self-tested in CI but not yet run on a real Mac**, so expect rough edges.
* The controller input pipeline (deadzones, trigger hysteresis, SOCD), Sony report checksums, input traces and the save-state container, all unit tested.

## Not done yet (Game Boy)
Compatibility mode for original-Game-Boy games on colour hardware (palette selection), MBC7 (tilt) cartridges, MBC1 multicart, pixel-exact PPU timing, save-state slots and rewind in the UI, a game library.

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
