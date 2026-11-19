# Architecture (short)

* `EmulatorKit`: the `EmulatorCore` contract, input/output protocols, save-state container. Standard library only.
* `GBCore`, `GBACore`, `PS1Core`: emulator cores (stubs until M1, M3, M6). They depend only on `EmulatorKit`, `EmuSupport`, `PSG`, `DiscFormats`, so they build and test on Linux.
* `ControllerModel`: controller types and the input pipeline. `ControllerKit` (macOS) connects it to GameController.
* `PlatformKit` (macOS): Metal video, audio, emulation session. `WindowsKit` (macOS): Wine bottles.
* `Attic` (macOS executable): the SwiftUI app. `rom-test`, `emu-bench`, `core-selftest`, `controller-dump`: command-line tools.

Each core runs on one dedicated thread. Hot loops use final classes and raw pointers, with `-Ounchecked` in release builds only. See [PLAN.md](PLAN.md) sections 3 and 6.
