# Implementation plan: a native-Swift game app for macOS
**Windows · PlayStation · Game Boy / GBC / GBA first, with full Xbox / PS4 / PS5 controller support**  ·  18 October 2026  ·  Repo `jjshah230309/Port-Windows`, branch `claude/dreamy-cerf-k06c54`  ·  Working name **Attic** (placeholder)

> **Executive summary**
> * **What it is:** one Mac app, written in Swift and built without Xcode, that plays games you own: Windows PC games, PS1 discs, and Game Boy / GBC / GBA cartridges.
> * **How it works:**
>   * The handheld and PS1 systems are emulated by our own Swift code.
>   * Windows games run through Wine, a separate engine that the app downloads and manages, with automatic graphics selection (DXVK, or D3DMetal when you have Apple's toolkit).
> * **Controllers (§8):** full support for Xbox One / Series X|S / Elite 2 / Adaptive, DualShock 4 (both revisions) and DualSense / DualSense Edge, over Bluetooth and USB, in the emulators and in Windows games.
>   * Every feature macOS allows is covered: rumble, trigger rumble, adaptive triggers, touchpad, motion, lightbar, player LEDs, paddles and battery.
>   * The few things macOS can't do are listed with workarounds.
> * **Schedule:**
>   * Game Boy is first, because it's small and proves the whole pipeline.
>   * The Windows MVP comes in about 6–9 months: $1.5 + 5.5 + 6 + 9 + 5.5 = 27.5$ to $37.5$ weeks, adding up M0–M4.
>   * PS1 is the largest piece, at about 7–10 months.
>   * Controller work adds about 13 weeks, spread across the milestones.
>   * PS2, Xbox emulation and more Nintendo systems are later phases.
> * **Biggest risks:** Swift performance in tight loops, Apple's planned Rosetta wind-down after macOS 27, the D3DMetal license, and wired-USB Xbox limits on macOS. Each has a mitigation (§14).

---

## 1. Context
You want to play games you already own on a MacBook in **one native Swift app, built without Xcode**, with **full support for Xbox, PS4 and PS5 controllers**.
- `Port-Windows` is empty (README only), so everything here is new.
- Your `frameup` repo already has three patterns this plan reuses as patterns, not code:
  - Swift built with plain `swiftc` + `lipo` (`frameup/scripts/build-apple.js`).
  - Pinned tools downloaded on first run, with a Tools status panel (`frameup/src/tools.js`).
  - 3-OS CI producing unsigned releases on `v*` tags (`frameup/.github/workflows/build.yml`).
- `frameup` itself is not changed.

## 2. Decisions

| Topic | Decision |
|---|---|
| Native Swift | The app **and** the GB/GBC, GBA and PS1 emulator cores are written from scratch in Swift. No libretro, no wrapped emulators. |
| Windows | Wine runs as a separate engine process, managed by the Swift app (like the old Whisky app). |
| Windows graphics | DXVK + MoltenVK by default (downloaded automatically). D3DMetal is used when you import Apple's Game Porting Toolkit. The choice is automatic per game, with an override. |
| PlayStation | PS1 now. PS2 is a later phase. |
| Controllers | Full Xbox, PS4 and PS5 support. Apple's GameController framework is the main path, with an opt-in raw-HID layer for the few extras Apple doesn't expose. Wine games get controller passthrough, configured per bottle (§8). |
| Target Mac | Apple silicon, **macOS 15+**. Apple-silicon builds only. |
| Dependencies | **No third-party Swift packages.** Small utilities (inflate, PNG, hashing, CRC32) are written in-house. |
| Concurrency | Swift 6. Each core runs on one dedicated `Thread`. async/await is used only for UI, downloads and Wine processes. |
| Licensing | App is MIT (like frameup). Wine (LGPL), DXVK (zlib) and MoltenVK (Apache-2.0) are downloaded and run out-of-process, never linked. |
| Clean-room policy | We implement from hardware documentation (Pan Docs, GBATEK, psx-spx, Linux `hid-playstation.c` for report layouts) and test suites. We don't copy code from GPL or non-commercial emulators. |

Why macOS 15:
- Swift's `Synchronization` (`Atomic`/`Mutex`) needs it.
- It's the first macOS with wired-USB Xbox controllers.
- Rosetta on 15 runs the AVX/AVX2 code many modern games need.
- Every Apple-silicon Mac can run it.

---

## 3. Architecture

```
            ┌──────────────────────── AtticApp (SwiftUI library · AppKit player window) ───────────────────────┐
            │  Library · Settings · Controllers pane + tester · Firmware manager · Engines panel · Bottles UI   │
            └───────┬──────────────────────────────┬─────────────────────────────────────┬─────────────────────┘
                    │                              │                                     │
   PlatformKit (Metal video · audio)   ControllerKit (GameController + opt-in HID)   WindowsKit ──spawns──► Wine process
                    │                              │  input/output mailboxes             │   (x86_64 via Rosetta)
            EmulatorKit protocol (pure Swift) ◄────┘                                     │   DXVK · D3DMetal · wined3d
          ┌─────────┬───────────┬───────────┬──────────────────┐                         │   winebus opens the pads
        GBCore    GBACore     PS1Core    DiscFormats   ControllerModel   ← stdlib-only, so they build and test on Linux
```

### Core contract (`Sources/EmulatorKit/EmulatorCore.swift`)

```swift
public protocol EmulatorCore: AnyObject {
  static var info: SystemInfo { get }            // exact fps (num/den), audio rate, aspect, pad ports/devices
  init(media: MediaSource, firmware: FirmwareSet, options: CoreOptions, clock: HostClock) throws
  func reset(hard: Bool)
  func runFrame(input: InputSource, output: OutputSink)  // input latched on first guest pad read; rumble/light out
  var video: VideoFrame { get }                  // raw BGRA pointer, valid until the next runFrame
  func drainAudio(_ sink: (UnsafeBufferPointer<Int16>) -> Void)
  var battery: BatterySave? { get }
  func saveState(into w: inout StateWriter)
  func loadState(from r: inout StateReader) throws
}
```

- `HostClock` is injected, so real-time clocks are deterministic in tests.
- Save states use a chunked binary format (`"ATST"`, version, game hash, tagged chunks).
- Rewind is a ring of XOR-delta + RLE states (GB/GBA in M2).

### Platform layer (PlatformKit)

**Session thread**
- Commands go through a `Mutex` and are applied at frame boundaries.
- Video uses an atomic triple buffer.

**Video**
- `CAMetalLayer`, driven by `NSView.displayLink`.
- Shaders are written by us: nearest/integer, sharp-bilinear, CRT, LCD grid, and GBC/GBA colour correction.
- Shaders are compiled **at runtime from source strings**, because the `metal` compiler ships only with Xcode.

**Audio**
- `AVAudioSourceNode` pulls from a lock-free ring buffer, and a resampler converts to 48 kHz.
- Dynamic rate control absorbs the GB/GBA refresh mismatch:

$$f_{\text{GB}} = \frac{4\,194\,304}{70\,224} \approx 59.73\ \text{Hz}, \qquad \left|\frac{60 - 59.73}{59.73}\right| \approx 0.45\% < 0.5\%$$

  Because the gap is under 0.5%, we run at the display rate and let the audio resampler absorb the drift.

**Input**
- Controllers are handled by **ControllerKit** (§8).
- The keyboard uses `GCKeyboard` with layout-independent key codes and SOCD handling.

**Saves**
- Battery saves are written by atomic replace, debounced.
- Formats stay compatible with other emulators: `.sav`, the MBC3 RTC trailer, `.mcd`.
- 10 state slots plus auto-save, with thumbnails.

### Storage
- App data: `~/Library/Application Support/Attic/{library.json, settings.json, controllers/, firmware/, saves/, states/, Engines/, Bottles/}`
- Logs: `~/Library/Logs/Attic/`

---

## 4. Repository layout (key files)

```
Port-Windows/
├─ Package.swift                       targets below; macOS-only targets behind #if os(macOS)
├─ Resources/  Info.plist  Attic.entitlements  AppIcon-1024.png  components.json  compat/windows.json
│              controllers/ (default profiles, glyph fallbacks, PS1 per-disc pad DB, GBA sensor DB)  Licenses/
├─ scripts/    build-app.sh  make-icon.sh  fetch-test-roms.sh  pin-component.sh  check-hot-loops.sh
├─ Sources/
│  ├─ EmulatorKit/     EmulatorCore, SystemInfo, VideoFrame, InputSource/OutputSink, StateCodec, Scheduler, HostClock
│  ├─ EmuSupport/      Inflate, PNG, CRC32, SHA1/256, XXH64, Cabinet
│  ├─ DiscFormats/     CueSheet, BinImage, ISO9660, SystemCNF, M3U, (CHD later)
│  ├─ PSG/             square/wave/noise channels + band-limited synth (shared by GB and GBA)
│  ├─ GBCore/          SM83 CPU, Bus, MBC 1/2/3+RTC/5(rumble)/7(accelerometer), PPU, APU, Timer, HDMA, PostBoot
│  ├─ GBACore/         ARM7TDMI, PPU modes 0–5, DMA, Timers, DirectSound, Backup, HLEBIOS, GPIO (RTC/gyro/tilt/solar/rumble)
│  ├─ PS1Core/         R3000A + cached interpreter, GTE, GPU, SPU, CDROM, MDEC, DMA, SIO0 pad bus (pad/DualShock/
│  │                   multitap/mouse/neGcon/GunCon), BIOS/TestKernel
│  ├─ ControllerModel/ pure Swift: ControllerID/Capabilities, RawControllerState, InputPipeline (deadzones, SOCD, turbo),
│  │                   Bindings, Profiles, Hotkeys, PlayerAssignment, Sony/Xbox HID report parsers + CRC32,
│  │                   InputMailbox/OutputMailbox, VirtualController, TraceRecorder/Replayer
│  ├─ WinFormats/      PE imports/resources, .lnk, Valve .acf/.vdf, .reg
│  ├─ CoreTestSupport/ headless runner, pass criteria, manifests, JUnit/Markdown reports
│  ├─ rom-test/  emu-bench/  core-selftest/  controller-dump/   (command-line tools)
│  ├─ PlatformKit/     Video/ Audio/ Session/                        [macOS]
│  ├─ ControllerKit/   Registry, GameControllerBackend, KeyboardBackend, HIDExtras, Glyphs, Haptics, Motion,
│  │                   Lights, AdaptiveTriggers, Battery                [macOS]
│  ├─ WindowsKit/      Engines/ Bottles/ (incl. WineBusConfig) Launch/ Verbs/ Stores/ Logs/   [macOS]
│  └─ AtticApp/        App, Library/, Player/, Controllers/ (pane, tester, remap), Windows/, Settings/   [macOS executable]
├─ Tests/      one test target per module; Manifests/{gb,gba,ps1}.json; Fixtures/hid/ (captured reports);
│              Traces/ (recorded input); WindowsProbe/ (mingw-built probe .exe: XInput/DInput/WGI/raw-HID + d3d9/11/12)
├─ .github/workflows/ci.yml
└─ docs/       ARCHITECTURE.md  LEGAL.md  DUMPING.md  COMPATIBILITY.md  CONTROLLERS.md  PERFORMANCE.md
```

- Hot-loop modules get `-Ounchecked -enforce-exclusivity=unchecked` in release builds only. Debug builds keep every safety check.
- `controller-dump` prints every element, haptic locality, motion flag and HID descriptor for each connected pad. Its output becomes the hardware fixtures that CI tests replay.

---

## 5. Building without Xcode

```bash
swift build                          # macOS: everything · Linux: cores, ControllerModel, formats, CLIs
swift test                           # unit tests (see the Command Line Tools note below)
swift run core-selftest              # framework-free checks; always works with Command Line Tools only
scripts/fetch-test-roms.sh && swift run -c release rom-test --all --md report.md --junit report.xml
swift run controller-dump            # on a Mac with pads connected: capability/HID fixture dump
scripts/build-app.sh && open dist/Attic.app
```

`build-app.sh` steps:
1. `swift build -c release --product Attic` (arm64 only, single architecture).
2. Assemble `Attic.app/Contents/{MacOS,Resources}`.
3. Patch the version into `Info.plist` with `plutil`.
4. Build the icon with `sips` + `iconutil`.
5. Ad-hoc sign: `codesign --force --sign - --entitlements …`, then verify.
6. Package with `ditto` (zip) and `hdiutil` (dmg).

**Info.plist keys (controller-relevant ones included):**

| Key | Value | Purpose |
|---|---|---|
| `LSApplicationCategoryType` | `public.app-category.games` | Lets macOS treat Attic as a game |
| `GCSupportsGameMode` | `true` | Game Mode in native full screen (doubles the Bluetooth controller sampling rate) |
| `LSSupportsGameMode` | `true` | Same as above, the macOS 26 key |
| `GCSupportsControllerUserInteraction` | `true` | System Settings per-app controller remapping (to verify for non-App-Store apps) |
| `GCSupportedGameControllers` | `[ExtendedGamepad]` | Same as above |
| `NSInputMonitoringUsageDescription` | short explanation | Shown only if the opt-in raw-HID extras trigger Input Monitoring |
| `NSMicrophoneUsageDescription` | short explanation | Only if a DualSense mic capture feature is used |

**Entitlements:**
- `allow-jit`, for a future JIT.
- No sandbox, because Wine needs to start processes and IOHID access must not be restricted. Because of that, the app ships outside the App Store.

| Works with the Command Line Tools only | Missing or to verify → workaround |
|---|---|
| `swiftc`, SwiftPM, AppKit, SwiftUI, Metal, AVFoundation, GameController, CoreHaptics, IOKit/HID, CryptoKit | `metal` compiler → runtime shader compilation |
| `codesign`, `plutil`, `sips`, `iconutil`, `hdiutil`, `lipo`, `sample` | `actool`/`ibtool` → no asset catalogs or xibs; all UI in code |
| | XCTest / swift-testing under `swift test` (to verify) → `core-selftest` and `rom-test` executables |
| | Instruments → `sample`, an in-app frame-time HUD, `perf` on Linux |

---

## 6. Emulator cores

### Hot-path rules (enforced in CI by `check-hot-loops.sh`)

- **Memory**
  - Components are `final class`es.
  - Guest memory is allocated once as raw pointers. No `Array` in the hot loop.
- **Dispatch**
  - No protocols or closures in the hot loop.
  - Instruction dispatch is a `switch` over decode tables.
  - Mapper and pad-device dispatch is an `enum` switch.
- **Code shape**
  - Explicit wrapping arithmetic.
  - `@inline(__always)` on memory fast paths, `@inline(never)` on I/O slow paths.
  - Event scheduler for timers, DMA and video timing.
- **CI check:** the build fails if the disassembly of a core's frame loop contains `swift_retain`, `swift_release` or `swift_beginAccess`.

| Core | Main components | BIOS / boot |
|---|---|---|
| **GB/GBC** (M1) | SM83 with M-cycle timing, HALT bug, CGB double speed; scanline PPU (pixel FIFO later); PSG APU; MBC1/2/3+RTC/5 (rumble)/7 (accelerometer) | **No boot ROM needed.** We set the post-boot registers ourselves (DMG: `AF=01B0 BC=0013 DE=00D8 HL=014D SP=FFFE PC=0100`) and reproduce the CGB palette choice for DMG games. |
| **GBA** (M3) | ARM7TDMI (ARM/Thumb, banked modes); waitstates + prefetch; PPU modes 0–5, affine, windows, blending, mosaic; DirectSound FIFOs; save-type auto-detect; cartridge GPIO (RTC, gyro, tilt, solar, rumble) | Your BIOS if present. Otherwise our own stub BIOS + **HLE** of the common SWIs, with a differential test against a real BIOS. |
| **PS1** (M6) | R3000A → cached interpreter; GTE; software GPU, exact to hardware rules; SPU (24 voices, reverb); CD-ROM with timing (`.cue/.bin`, `.m3u`, later `.chd`); MDEC; DMA; SIO0 pad bus with pluggable devices; memory cards | Your BIOS (matched by hash), with fast boot. **OpenBIOS** (PCSX-Redux, reportedly MIT, to verify) as an optional download. A minimal test kernel lets CI run without any Sony BIOS. |

### Performance targets
Measured with `emu-bench` on an M1 Air, where $\text{speed} = \frac{\text{emulated frames per second}}{\text{native fps}}$:

| Core | Guest clock | Target | Gate |
|---|---|---|---|
| GB/GBC | $4.19$ / $8.39$ MHz | $\ge 30\times$ | M1 |
| GBA | $16.78$ MHz | $\ge 4\times$ (aim for $6\times$) with the interpreter | M3 |
| PS1 | $33.87$ MHz + software GPU | plain $\ge 1.2\times$; cached $\ge 1.5\times$ | **M6a, early** |
| PS2 (later) | $294.9$ MHz EE + VU0/VU1 | interpreter ≈ $5$–$15\%$ (estimate) | **JIT required** |

JIT (PS2, optionally PS1):
- A from-scratch arm64 emitter.
- Code memory from `MAP_JIT`, with `pthread_jit_write_protect_np` around writes and `sys_icache_invalidate` after them.
- Tested in lockstep against the interpreter.

---

## 7. Windows layer (WindowsKit)

### Engines (pinned in `components.json`, frameup's tools pattern)

| Component | Source | Notes |
|---|---|---|
| Wine | Gcenx `macOS_Wine_builds` (pinned tag + sha256) | x86_64 under **Rosetta**. Includes wine-mono and wine-gecko. Uses Wine 11's WoW64. Bundled SDL2 for controllers (to verify with `otool -L winebus.so`). |
| DXVK-macOS | Gcenx repack v1.10.3 | DX10/11 → Vulkan. Stale (2023), which is a risk. |
| MoltenVK | Bundled in Wine; optional KhronosGroup override | Vulkan → Metal |
| D3DMetal | **You import** your own downloaded GPTK `.dmg` | We check Apple's signature and show Apple's license. **Never bundled or redistributed.** Needs a GPTK-compatible Wine. |
| GStreamer | Official `.pkg`, optional | Needed for Media Foundation cutscenes |

- Install flow: download → sha256 check → extract → probe (`wine --version`). Runtime downloads use pinned URLs only.
- Rosetta: check with `arch -x86_64 /usr/bin/true`. If missing, prompt and install with `softwareupdate --install-rosetta`.

### Bottles and launching

**Bottles**
- One `WINEPREFIX` per bottle.
- Setup is `wineboot --init` plus a single batched `.reg` file:
  - Windows 10 mode
  - Retina mode + 192 DPI
  - Option/Command key mapping
  - controller settings (§8.5)

**Launching**
- `Process` with a curated environment: `WINEPREFIX`, `WINEDEBUG`, `WINEDLLOVERRIDES` per backend, plus msync/esync and AVX settings when the engine supports them.
- Lifecycle:
  - `wineserver -w` detects when a game exits.
  - `wineserver -k` is "Force Quit". It is also required before changing controller settings.
- Logs go to `~/Library/Logs/Attic/Wine/<bottle>/`.

**Components and stores**
- Component installs download from Microsoft at install time: VC++ 2015–22, DirectX June 2010, .NET 4.8, core fonts, d3dcompiler_47.
- Stores:
  - **Steam:** installer from Valve, `.acf` import, `-applaunch <id>`.
  - **GOG:** offline installers.
  - **Epic:** MSI installer (flaky).

### Automatic graphics selection
Order of precedence: your per-game override → the compat database → a scan of the exe's imported DLLs.

| API detected | GPTK imported | No GPTK |
|---|---|---|
| DX12 (64-bit) | **D3DMetal** | Warn "needs GPTK" |
| DX11 / DX10 (64-bit) | **D3DMetal** | **DXVK** |
| DX11 / DX10 (32-bit) | DXVK | DXVK |
| DX9 and older | wined3d (OpenGL) | wined3d |
| Vulkan | winevulkan → MoltenVK | winevulkan → MoltenVK |

> **Compatibility, honestly**
> * **Likely works:** DX9–11 single-player games, Unity/UE4 titles, GOG classics, and many DX12 games with D3DMetal.
> * **Needs tweaks:** .NET/VC++ dependencies, video cutscenes (GStreamer), AVX2 games, launchers.
> * **Will not work:**
>   * kernel-level anti-cheat (Vanguard, FACEIT, Ricochet, most BattlEye/EAC configurations)
>   * kernel-driver DRM
>   * AVX-512-only games
>   * VR
>   * anything that needs Windows drivers
>   * Microsoft GameInput-only titles (Wine only stubs that API)

---

## 8. Controllers: full Xbox, PS4 and PS5 support

> **Bottom line**
> * Every controller feature that macOS allows is supported, over **Bluetooth and USB**, in the emulators and in Windows games.
> * Apple's **GameController** framework covers almost everything.
> * A small **opt-in raw-HID layer** adds the extras Apple doesn't expose:
>   * DualSense Edge paddles and Fn buttons
>   * the DualSense mute button and LED
>   * custom player-LED patterns
>   * raw touchpad data
>   * device identity
> * **What macOS doesn't allow:**
>   * Wired-USB Xbox gets no rumble or Share button through Apple's API, so use Bluetooth for those. An experimental raw-HID rumble path is planned.
>   * DualSense HD haptics, speaker and mic work only over USB.
>   * The Xbox Wireless Adapter dongle is not supported on macOS.
> * Effort: $0.5+1.5+2+1+1.5+1+3+2.5 = 13$ weeks, spread across M0–M7 (§11).

### 8.1 Approach: three layers

| Layer | Provides | How |
|---|---|---|
| **GameController** (primary, always on) | Input for every pad, rumble, Xbox trigger rumble, DualSense adaptive triggers, lightbar, motion, touchpad, battery, glyphs | `GCController.input` (`GCControllerLiveInput`, macOS 14) on a private queue with buffered states. The touchpad and adaptive triggers come from `GCDualSenseGamepad` / `physicalInputProfile`. Also `.motion`, `.haptics`, `.light` and `.battery`. |
| **HID extras** (opt-in "Advanced controller features", off by default) | VID/PID/serial identity; Edge Fn and paddles; DualSense mute button/LED + real mic mute; player-LED patterns and brightness; raw touchpad (finger-down flag, 12-bit coordinates); **experimental** wired-Xbox rumble | IOHIDManager. Devices are opened **non-exclusively** (never seized), with gamepad/joystick usages only. Raw report decoder for DS4 `0x11` / DualSense `0x31` over Bluetooth, with CRC32 checks. |
| **Wine passthrough** | Windows games | Wine's own `winebus` opens the pad. Attic configures each bottle (§8.5) and steps aside while a game runs. |

**Coexistence rules**
- **One output owner** per pad per feature. GC haptics and raw rumble never run at the same time.
- HID matching skips the synthetic "compatibility" Xbox 360 twins that macOS creates.
- Attic always disables system gestures on Home / Share / Create (`preferredSystemGestureState = .disabled`). The Home button is never required; hotkeys use chords.
- A GC controller is matched to its HID device with `GCController.supportsHIDDevice(_:)`, the controller family, and a "press a button to claim" step.

**Permissions**
- GameController needs no permissions.
- Raw HID *may* trigger Input Monitoring. Sources conflict on this.
  - That is why HID extras are off by default.
  - If access is denied (`kIOReturnNotPermitted`), we fall back to GameController with a notice.
- Ad-hoc rebuilds may reset permission grants.
- Wired pads may show a first-connect approval prompt.

### 8.2 Modules

**ControllerModel** is pure Swift and tested on Linux. It holds:
- types and the input pipeline
- bindings, profiles, hotkeys and player assignment
- Sony and Xbox HID report parsers and builders
- mailboxes
- the virtual controller and trace record/replay

**ControllerKit** is macOS only. It holds:
- the registry and hot-plug handling (`GCControllerDidConnect`, `GCControllerDidDisconnect`)
- the GameController and keyboard backends
- HID extras
- glyphs (`sfSymbolsName`, with bundled PlayStation/Xbox fallbacks)
- haptics (CoreHaptics)
- motion (bias, low-pass filter, recentre)
- lights and adaptive triggers
- battery (KVO on `battery`, with a 30 s timer fallback)

```swift
public struct ControllerID: Hashable, Codable, Sendable {   // persistence key; GC exposes no serial, HID adds it
  public var family: ControllerFamily    // .xboxOne .xboxSeries .xboxElite2 .xboxAdaptive .dualShock4 .dualSense .dualSenseEdge .generic
  public var serial: String?; public var vidPid: UInt32?; public var transport: Transport }   // .usb / .bluetooth
public struct ControllerCapabilities: OptionSet, Sendable {   // probed at connect, never assumed per model
  public let rawValue: UInt32 }  // .rumble .triggerRumble .adaptiveTriggers .hdHaptics .touchpad .motion .lightbar
                                 // .playerLEDs .muteLED .battery .share .paddles .home .audio
public protocol HapticsOutput: Sendable {
  func setRumble(low: Float, high: Float)          // 0...1 (PS1 large motor → low, small → high)
  func setTriggerRumble(left: Float, right: Float); func stopAll() }
public struct RawControllerState: Sendable {        // fixed-size POD, no ARC
  public var buttons: UInt64; public var left, right: SIMD2<Float>; public var lt, rt: Float
  public var touch: (TouchPoint, TouchPoint); public var gravity, rotationRate: SIMD3<Float>  // g, rad/s
  public var battery: Float; public var t: UInt64 }
```

**Getting input to the emulation thread without locks**
- GC input arrives on a private queue (`inputStateQueueDepth ≈ 32`, drained with `nextInputState()`). It is normalised there and published to an `InputMailbox`.
- `InputMailbox` is a single-producer, single-consumer seqlock built on `Atomic<UInt64>`.
- The core latches input **on the first guest pad read** of each frame (GB `JOYP`, GBA `KEYINPUT`, PS1 SIO0, sensors). This gives the freshest input, and the latched value goes into the trace so replays are exact.
- **Output** goes the other way through an `OutputMailbox`:
  - It is written only on committed frames, so run-ahead frames stay silent.
  - A dedicated queue coalesces updates to ≤60 Hz before CoreHaptics, so a slow call never stalls the core.

**Haptics rules**
- One `CHHapticEngine` per locality: left handle and right handle, plus the triggers only when `supportedLocalities` lists them.
- Each engine plays one infinite continuous event whose intensity is set every frame.
- Engines restart on `stoppedHandler` / `resetHandler`.
- `CHHapticAdvancedPatternPlayer` is never used, because it fails on controllers.
- A "swap trigger sides" toggle covers pads whose trigger motors are reported reversed.

### 8.3 Feature matrix
Cell codes:
- **GC**: GameController API
- **HID**: opt-in raw HID
- **CA**: Core Audio (USB)
- **—**: not on the hardware
- **✗**: not possible on macOS
- **?**: to verify on hardware

| Pad | Buttons / sticks / triggers | Share / Create | Home | Paddles / Fn | Rumble | Trigger rumble | Adaptive triggers | HD haptics | Touchpad | Motion | Lightbar | Player LEDs | Mute | Battery | Audio jack / speaker / mic |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Xbox One S/X (BT) | GC | — | GC² | — | GC | GC?⁴ | — | — | — | — | — | — | — | GC | ✗ |
| Xbox Series X\|S (BT) | GC | GC¹ | GC² | — | GC | GC?⁴ | — | — | — | — | — | — | — | GC | ✗ |
| Xbox Series / One (USB, macOS 15+) | GC | ✗¹ | GC² | — | HID?³ | HID?³ | — | — | — | — | — | — | — | ? | ? |
| Elite Series 2 (BT) | GC | — | GC² | GC⁵ | GC | GC?⁴ | — | — | — | — | — | — | — | GC | ✗ |
| Elite Series 2 (USB) | GC | — | GC² | GC?⁵ | HID?³ | HID?³ | — | — | — | — | — | — | — | ? | ? |
| Adaptive Controller | GC (BT); USB ?⁶ | — | GC² | — | — | — | — | — | — | — | — | — | — | — | — |
| DualShock 4 v1/v2 (USB) | GC | GC | GC² | — | GC | — | — | — | GC (+HID raw) | GC | GC | — (lightbar colour) | — | GC | ? |
| DualShock 4 v1/v2 (BT) | GC | GC | GC² | — | GC | — | — | — | GC (+HID raw) | GC | GC | — (lightbar colour) | — | GC | ✗ |
| DualSense (USB) | GC | GC | GC² | — | GC | — | GC | CA⁷ | GC (+HID raw) | GC | GC?⁸ | GC? / HID | HID | GC | CA |
| DualSense (BT) | GC | GC | GC² | — | GC | — | GC | ✗⁷ | GC (+HID raw) | GC | GC?⁸ | GC? / HID | HID | GC | ✗ |
| DualSense Edge (USB / BT) | GC | GC | GC² | HID?⁹ | GC | — | GC | CA (USB) / ✗ (BT) | GC (+HID raw) | GC | GC?⁸ | GC? / HID | HID | GC | CA (USB) |

Notes:
1. **Share.** The Xbox Series Share button is `GCXboxGamepad.buttonShare` (macOS 12). The system reserves it for screenshots, so Attic disables that gesture. Over wired USB on macOS 26 it is not delivered (Apple bug FB21568043).
   - Naming trap: the DS4 Share and DualSense Create buttons arrive as `buttonOptions`, and Options is `buttonMenu`. On Xbox, View is `buttonOptions` and Menu is `buttonMenu`.
   - Bindings store Apple's element names and show the PlayStation/Xbox names.
2. **Home** is system-owned. macOS 26 uses it to open the Game Overlay unless the gesture is disabled, and macOS 27 adds `GCControllerHomeButtonSettingsManager` (to verify). Attic never requires Home.
3. **Wired Xbox rumble** doesn't work through GameController (observed on macOS 26.1).
   - Candidate fix: IOHID output report `0x01` carrying a GIP rumble packet, including the trigger motors. This rests on one unverified third-party source, so it is opt-in and experimental.
   - Otherwise the UI shows a hint: "use Bluetooth for rumble".
   - The original Xbox One pads (models 1537/1697) have no Bluetooth, so they are USB-only.
4. **Xbox trigger rumble** uses `GCHapticsLocality.leftTrigger` / `.rightTrigger`. It is enabled only when the pad's `supportedLocalities` lists it.
5. **Elite paddles** are `paddleButton1…4`. They appear only on the default hardware profile (profile LEDs off), and the UI explains this.
6. **Adaptive Controller:** Apple lists it for Bluetooth only. Its USB behaviour is to be verified. Its extra jacks surface as ordinary buttons.
7. **DualSense HD haptics** work over USB only.
   - Attic streams 4-channel 48 kHz audio to the pad's USB audio device (channels 3–4 drive the voice coils). The device must be set to Quadraphonic; doing that programmatically is to be verified.
   - Over Bluetooth, Attic falls back to rumble emulation. The unofficial Bluetooth haptics report is lossy and stays off.
8. Apple documents `GCDeviceLight` only for the DS4. DualSense lightbar control through it is assumed and must be verified; HID is the fallback.
9. **Edge paddles and Fn:** first check `physicalInputProfile.buttons` on real hardware. Otherwise read the raw input bits (`0x10`/`0x20` = Fn, `0x40`/`0x80` = paddles).

Identification:
- `productCategory` plus capabilities: paddles mean Elite, Share means Series.
- With HID extras on, the VID/PID refines this:
  - Microsoft `045E`: `02E0/02FD/0B20` One S, `0B12/0B13` Series, `0B00/0B05/0B22` Elite 2, `0B0A/0B0C/0B21` Adaptive.
  - Sony `054C`: `05C4` DS4 v1, `09CC` DS4 v2, `0BA0` DS4 wireless adapter (HID only), `0CE6` DualSense, `0DF2` Edge.
- Third-party clones and the PlayStation Access controller get best-effort support through GameController.

### 8.4 Emulated systems: mappings and special hardware

**Common input pipeline**
- Order: raw → radial deadzone → response curve → trigger hysteresis → SOCD / opposing-direction filter → bindings → turbo → hotkey chords → core.
- Scaled radial deadzone, with defaults $d_i = 0.12$ and $d_o = 0.97$:

$$\mathbf v' = \hat{\mathbf v}\,\min\!\Big(\frac{\lVert\mathbf v\rVert - d_i}{d_o - d_i},\ 1\Big)\ \text{ for } \lVert\mathbf v\rVert > d_i,\ \text{else } \mathbf 0$$

- When a trigger acts as a button, it presses at $0.35$ and releases at $0.25$ (hysteresis).
- When a stick acts as a d-pad, it uses octants with a $0.5 / 0.4$ magnitude gate.
- Turbo counts emulated frames, so replays are exact.
- Motion samples are taken relative to a neutral pose, with gyro bias removed while $\lVert\omega\rVert < 0.03$ rad/s for $0.5$ s, and a $10$–$15$ Hz low-pass filter.
- Xbox pads have no motion sensors, so the right stick substitutes.
- Motion sensors run only while a motion game is active.

**GB / GBC** (layout: A = east face button, B = south; a "match printed labels" option is available)
- **MBC5 rumble** (cart types `0x1C–0x1E`).
  - Bit 3 of writes to `4000–5FFF` drives the motor, and is stripped before bank select.
  - Strength per host frame is the duty cycle $d = \frac{\sum t_{\text{on}}}{70\,224}$, where $70\,224$ is the T-cycles per frame.
  - Output is $s = \max(0.2,\, d)$ for $d > 0$, then a $30$–$50$ ms smoother.
- **MBC7 accelerometer** (Kirby Tilt 'n' Tumble, Command Master).
  - Latch with `0x55`, then `0xAA`. The registers are centred at `0x81D0`.
  - With a gain of $k \in [1, 1.5]$ and $g$ measured in units of gravity:

$$X = \text{0x81D0} - \mathrm{round}(112\,k\,g_x), \qquad Y = \text{0x81D0} + \mathrm{round}(112\,k\,g_y)$$

  - The signs are confirmed with Kirby's calibration screen.
- **Not mappable:** the IR port always reports "no light", and the link cable and Printer are out of scope.

**GBA** (special hardware is selected by the 4-character game code; it uses the cartridge GPIO at `0x080000C4`)
- **Gyro** (WarioWare: Twisted!, `RZW*`). It is a 12-bit serial ADC, stopped at about `0x6C0`, with clockwise rotation giving larger values:

$$\mathrm{adc} = \mathrm{clamp}\big(\text{0x6C0} + K\,\omega_{\text{cw}},\ 1,\ 4094\big), \qquad K \approx \tfrac{2.2\times10^{9}}{20\cdot 2^{21}} \approx 52 \text{ counts per rad/s}$$

  - The rotation axis and sign are **per-profile settings**, with defaults derived on hardware.
  - Xbox pads use a left-stick "twist" instead.
- **Tilt** (Yoshi Topsy-Turvy, Koro Koro Puzzle). Latch `0x55` / `0xAA` at `E008000/E008100`. Here $78.5 = 8$ counts per m/s², times $9.81$:

$$X = \text{0x3A0} - \mathrm{round}(78.5\,g_x), \qquad Y = \text{0x3A0} + \mathrm{round}(78.5\,g_y)$$

  - Values are clamped to 12 bits, with a per-game invert.
- **Solar sensor** (Boktai series).
  - The level $\ell \in [0, 10]$ comes from the right trigger or the touchpad.
  - Then $v = \text{0x16} + L[\ell - 1]$ and the sample is $\text{0xFF} - v$.
  - The $L$ table and the pin roles come from mGBA/MAME behaviour and must be verified against a real cartridge trace.
- **Rumble** (Drill Dozer, WarioWare: Twisted!) uses the same duty-cycle integrator as GB.

**PS1** (the SIO0 pad bus takes pluggable devices; the device type comes from a per-disc database, with a manual override)

| Emulated device | Host mapping |
|---|---|
| Digital pad (`5A41`) | Face buttons / d-pad |
| DualShock (`5A73`; config commands `43–4D`) | Sticks via $b = \mathrm{round}(128 + 127x)$ for $x \ge 0$ and $\mathrm{round}(128 + 128x)$ for $x < 0$. Analog button = Create / touchpad click. The lightbar shows red in analog mode. |
| DualShock rumble | Large motor (8-bit) → low/left: $s_L = \max\big(0.2,\ (v/255)^{1.5}\big)$ for $v > 0$. Small motor (on/off) → high/right at $0.6$–$1.0$. |
| Multitap (`5A80`) | 8 player slots; DS4/DualSense lightbar colours identify slots 5–8 |
| Mouse (`5A12`) | Touchpad: $\Delta = \mathrm{clamp}\big(\mathrm{round}(160\,s\,\Delta p),\,-128,\,127\big)$, where $\Delta p$ is the fraction of the pad width moved and $s$ is a sensitivity factor |
| neGcon (`5A23`) | Gyro steering: $\text{twist} = \mathrm{clamp}\big(\mathrm{round}(128 + 127.5\,\theta/\theta_{\max}),\,0,\,255\big)$ with $\theta_{\max} = 45^\circ$. Xbox: left stick with a cubic curve. |
| GunCon (`5A63`) | Aim with the host mouse, right stick, gyro cursor or touchpad, converted to beam coordinates: $X = \frac{X_1 + \delta\,p_x + o_x}{c}$ and $Y = Y_1 + p_y + o_y$. The constants $c$ and $o_x$ are calibrated on Time Crisis and Point Blank. Trigger = R2. |
| Justifier (`5A31`) | Needs a beam-accurate light-gun IRQ, so it is a stretch goal in M6 |

**DualSense extras** (optional, per game)
- An adaptive-trigger "click" at the L2/R2 digital threshold.
- Player colours on the lightbar and player LEDs.

### 8.5 Windows games (Wine passthrough)
Facts from the Wine 11 source and a diff of CrossOver 26.3:
- `winebus` has an **SDL backend** (used for Xbox pads) and an **IOHID raw-HID backend** (Sony pads by default since Wine 9.1).
- Each pad uses exactly one backend.

| Pad (in Wine) | XInput | DirectInput | Windows.Gaming.Input | Raw HID (native Sony support in PC ports) |
|---|---|---|---|---|
| Xbox (BT) | ✓, 2 motors (Share and paddles dropped) | ✓ | ✓, including trigger rumble | — |
| Xbox (USB) | ✓ input; no rumble (Bluetooth recommended) | ✓ | ✓ | — |
| DS4 / DualSense / Edge, **native mode** (default) | ✗ | ✓ | raw controller only | ✓ lightbar, adaptive triggers, rumble, gyro/touch once the game drives reports |
| DS4 / DualSense / Edge, **XInput-compatible mode** | ✓ with rumble | ✓ | ✓ | ✗ (loses Sony-only features) |

**Not available in Wine on macOS:**
- Microsoft GameInput (a stub)
- XInput battery level (Attic shows battery itself)
- DualSense HD haptics
- DirectInput force feedback on DS4/DualSense

**Per-bottle settings Attic writes.** These live in `HKLM\System\CurrentControlSet\Services\WineBus`, and `wineserver -k` must run first. Each is gated on the Wine version.

| Value | Default | Purpose |
|---|---|---|
| `Enable SDL` | 1 | Xbox path |
| `Map Controllers` | 1 | XInput view of SDL pads (0 = raw joystick, which keeps Share and paddles for DirectInput) |
| `Devices\054c\Hidraw` = 0 | unset | Per-game **"XInput-compatible PlayStation" switch** (Wine ≥ 10.13) |
| `DisableHidraw` / `DisableInput` | 0 | Leave off |
| `map\*` | unset | SDL mapping strings for coarse remaps |

- Before the first launch, a probe `.exe` checks that `winebus` loaded SDL. Without it, Xbox pads disappear.
- **Steam:** Steam Input in Windows Steam under Wine is unreliable, so Attic advises disabling it per game. The alternative is to launch the Wine game as a non-Steam shortcut from native macOS Steam.
- **No double input:** while any Wine game runs, Attic suspends its own controller navigation, hotkeys and haptic/light/trigger output for those pads, and never seizes devices.
- **Remapping for Windows games**, in order:
  1. Wine-native SDL mapping strings and DirectInput hide/override (coarse).
  2. An optional XInput proxy DLL fed by Attic through shared memory (M5+, XInput titles only). It needs prebuilt Windows binaries.
  3. **A virtual HID gamepad is not possible** for an ad-hoc-signed app, because the entitlement is restricted.

### 8.6 Controller UI

**Controllers pane**
- A device list showing name, glyph, USB/BT badge, battery %, player slot and capability chips.
- Per-device actions: Identify (rumble and light flash), assign a player slot, choose a profile.

**Live tester** (diagram per controller family)
- Every button and stick, before and after the deadzone.
- Trigger bars with their thresholds.
- Touchpad with two fingers.
- Motion gauges with a recentre button.
- Rumble and trigger-rumble sliders.
- A DualSense adaptive-trigger lab (off / feedback / weapon / vibration / slope, with live position readout).
- Triggers are always reset to off when the pane closes.

**Remapping**
- Click an action, then press an input. Glyphs match the controller (✕○□△ vs ABXY).
- An option chooses whether to respect System Settings remapping.

**Other settings**
- A deadzone and curve editor with a live scatter plot.
- Hotkeys:
  - Options/View/Create is the modifier.
  - Combined with R1 = save state, L1 = load, R2 = fast-forward, L2 = rewind, R3 = recentre, and Menu = quit.
  - Elite paddles can be bound.
  - Single-button alternatives exist for accessibility.
- **Player assignment:** 8 slots, claimed by pressing a button. Assignments persist per game and system. A disconnect pauses the game with "Reconnect Player N".

**Library navigation by controller**
- macOS SwiftUI has no gamepad focus support, so Attic includes its own navigation driver: d-pad/stick with repeat, A/✕ select, B/○ back, bumpers switch tabs.

### 8.7 Controller testing
**CI, with no hardware:**
- Virtual controllers and recorded traces feed the input pipeline. Run-ahead output must equal normal output frame for frame.
- **Golden protocol tests:**
  - MBC7 latch/centre
  - GBA gyro bitstream (`0x6C0` at rest), tilt and solar
  - PS1 digital/analog polls, DualShock config replies, multitap, GunCon off-screen
- **HID parser tests** use captured fixtures (DS4 v1/v2 × USB/BT, DualSense, Edge, Xbox BT, CRC32 seeds `0xA1`/`0xA2`).
- **Wine registry writer tests**, one per Wine version gate.

**Manual hardware matrix:** 11 controller/connection rows × macOS 15 / 26 / 27, checking:
- element enumeration (Share, paddles, Fn)
- rumble and trigger rumble, including the side swap
- wired-Xbox HID rumble
- motion axis and sign (Kirby, WarioWare)
- DualSense light and LEDs
- adaptive triggers
- battery
- permission prompts on a clean ad-hoc build
- latency with Game Mode on and off
- hot-plug and sleep/wake
- Wine probes (XInput / DInput / WGI / raw HID) with Attic and Wine running at the same time

---

## 9. Accuracy testing
`rom-test` runs each entry in `Tests/Manifests/*.json`. An entry has a path, sha256, frame limit, an input script, a pass criterion, and an expected result (`pass` or `known-fail`). CI fails on any regression.

**Pass criteria:**
- Blargg: serial-port text.
- Mooneye: the Fibonacci registers $3,5,8,13,21,34$.
- acid2 / ps1-tests: match the suite's reference images.
- Framebuffer hashes: used only to catch regressions.
- Determinism, for every core: run $600$ frames straight, and separately save at $300$, load, and run $300$ more. The two framebuffer hashes must match.

| Suite | Used for | CI? |
|---|---|---|
| Mooneye, dmg-acid2, cgb-acid2, Mealybug (MIT) | GB/GBC | Yes |
| Blargg (cpu_instrs, instr/mem_timing, halt_bug) | GB | Once its redistribution terms are confirmed; local until then |
| jsmolka gba-tests (MIT) | GBA arm/thumb/memory/ppu/save | Yes (the bios test is local) |
| mGBA suite (MIT, built from source) | GBA timing/DMA/IO | Local first, then CI |
| JaCzekanski ps1-tests (MIT) | PS1 cpu/gte/gpu/dma/timers/spu/mdec/cdrom | Yes |
| Amidog, PeterLemon, AGS aging cart | PS1 / GBA | Local only |

## 10. CI (`.github/workflows/ci.yml`, frameup's test → package → release pattern)

| Job | Runner | Does |
|---|---|---|
| `cores-linux` | ubuntu + `swift:6.x` container | build, `swift test` (cores + ControllerModel: pipeline, HID parsers, traces, protocol goldens), `rom-test --all`, hot-loop check |
| `windows-probes` | ubuntu + mingw-w64 | builds the probe programs (graphics + XInput/DInput/WGI/raw-HID) |
| `macos` | macos-15 (+ macos-26) | tests, `build-app.sh`, `Attic --self-test` (compiles all shaders, renders a known image, runs 60 frames per core, replays a controller trace), signature check |
| `clt-only` | macos-15 with `xcode-select` pointed at the Command Line Tools | **proves the no-Xcode build** |
| `engines-smoke` | nightly, non-blocking | downloads every pinned engine; `wineboot`; probes under DXVK; checks that winebus loads SDL |
| `release` | on `v*` tags | publishes the dmg + zip |

README install step: macOS 15 removed the Control-click → Open bypass. Use **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine /Applications/Attic.app`.

---

## 11. Milestones
These estimates assume one experienced developer working full time. Controller work is included in each row.

| # | Milestone | Duration | Exit criteria |
|---|---|---|---|
| **M0** | Scaffolding: Package.swift, modules, build script, icon, CI, README/LEGAL. **Controllers:** ControllerModel types, mailboxes, virtual controller, trace format, `controller-dump` | ~1.5 wk | CI green on Linux and macOS; the `.app` opens on a Mac with only the Command Line Tools; Metal self-test passes; CI replays a controller trace; `v0.0.1` published |
| **M1** | GB/GBC core + minimal player. **Controllers:** GameController backend + pipeline, keyboard + SOCD, gesture disable, MBC5 rumble, MBC7 | 5.5–7.5 wk | Blargg cpu_instrs 11/11 + timing; acid2 reference images match; Mooneye must-pass; stable $59.73$ fps with sound; $\ge 30\times$ bench; rumble on Series BT, DS4 and DualSense; Kirby calibrates; MBC7 goldens pass |
| **M2** | App shell: library, save states, battery saves, shaders, fullscreen, firmware manager, rewind. **Controllers:** pane, live tester, glyphs, remapping, profiles, hotkeys, 8-slot assignment, library navigation, battery | 6–8 wk | 30 minutes of play with zero audio underruns; save-state round trip; saves survive a relaunch; every matrix row enumerates; remaps persist across reconnects |
| **M3** | GBA core. **Controllers:** gyro, tilt, solar, rumble, sensor calibration UI, per-game invert | 9–13 wk | jsmolka suite passes on the HLE BIOS; $\ge 4\times$; 20 of your own games reach gameplay and save; WarioWare: Twisted!, Yoshi and Boktai playable; GPIO goldens pass |
| **M4** | Windows MVP: Wine + DXVK, Rosetta, bottles, run .exe, logs, components. **Controllers:** per-bottle WineBus config, version gating, SDL pre-flight probe, PlayStation XInput-compatible switch | 5.5–7.5 wk | Bottle created in under 60 s; D3D11 probe under DXVK; one of your DX11 games runs; Xbox BT + DualSense pass the XInput/DInput/WGI probes |
| **M5** | D3DMetal import + auto selection + Steam/GOG/Epic. **Controllers:** Steam Input guidance, double-input suppression, *(optional)* XInput proxy DLL | 5–9 wk (+1.5 wk optional) | DX12 probe renders under D3DMetal; one of your DX12 games launches; Steam installs and runs a game; Attic and a Wine game running together give no double input |
| **M6** | PS1, in steps: a CPU (perf gate) · b GTE · c GPU · d DMA/timers · e CD-ROM · f SPU · g MDEC · h pads/cards/OpenBIOS · i CHD · j cached interpreter. **Controllers:** SIO0 bus, DualShock config + rumble, multitap, mouse, neGcon, GunCon, DualSense extras | 6–9 mo + 3 wk | Each step passes its ps1-tests group; pad-protocol goldens pass; 25 of your own games reach gameplay, save, and play FMVs; a 4-player multitap game and a GunCon game work |
| **M7** | Polish + `v1.0.0`: update checker, disk-usage manager, accessibility, docs. **Controllers:** HID extras (Edge paddles/Fn, mute, player LEDs, BT decoder), USB HD haptics (opt-in), experimental wired-Xbox rumble, full hardware matrix | ~6.5 wk | Clean install on fresh macOS 15 and 26 accounts using only the README; the controller hardware matrix is signed off on macOS 15, 26 and 27 |

## 12. Later phases (roadmap)

| System | Feasibility in Swift | Notes |
|---|---|---|
| **PS2** | Multi-year (about 2–4 years to good compatibility) | EE + VU0/VU1 + IOP + GS; JIT required. DualShock 2 pressure-sensitive buttons are emulated from trigger depth or a modifier. |
| NES / SNES / DS / N64 | Realistic: 1–2 mo / 4–8 mo / ~1 yr / 1–2 yr | DS needs your BIOS and firmware; N64 needs a JIT + Metal RDP |
| Original Xbox | Low | x86 JIT + NV2A; needs your own dumps. 360 is far harder; One/Series are not feasible. |
| GameCube / Wii | Multi-year | — |
| **Switch** | **Not recommended** | Legal risk: Nintendo's case against Yuzu ended in a shutdown and settlement (2024), and Ryujinx stopped later that year |
| ARM64 Wine | Track | CodeWeavers' ARM64 + FEX work protects against the Rosetta wind-down |
| Link cable / GB Printer / GBA multiplayer | Later | Local multiplayer over IPC between instances; Printer output to PNG |

## 13. Legal guardrails
- **Nothing copyrighted is bundled:** no BIOS, keys, ROMs or GPTK. The firmware manager stores **hashes only**.
- `DUMPING.md` explains dumping your own cartridges, discs and console BIOS. Windows games come from your own Steam, GOG or Epic accounts.
- **Neutral branding:** no console or company trademarks or logos in the app name, icon or UI.
  - Controller glyphs are drawn by Apple's SF Symbols or by us, never copied artwork.
  - Run a trademark search on the final name.
- No DRM circumvention. Kernel anti-cheat titles are explicitly unsupported.

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Swift overhead in hot loops (ARC, exclusivity checks) | Cores too slow | §6 rules, CI disassembly check, early bench gates in M1, M3 and M6a |
| Rosetta wind-down (general use ends after macOS 27; macOS 28 keeps a games subset) | Windows layer, including Wine controller paths | Engines declare their architecture; track ARM64 Wine + FEX; emulators and controllers don't depend on Wine |
| D3DMetal license and its GPTK-Wine requirement | DX12 support | User-supplied GPTK; DXVK/wined3d fallback |
| Wired-USB Xbox on macOS 26 is degraded (no rumble, no Share, generic name) | Feature gaps for wired users | Recommend Bluetooth; experimental HID rumble (single unverified source); re-test on macOS 27 |
| Raw HID may need Input Monitoring; ad-hoc rebuilds may reset grants | Permission friction | HID extras are off by default; GameController-only fallback; clean-install testing |
| Home/PS/Share buttons are system-owned and change across macOS versions | Lost button presses | Disable gestures; chord hotkeys; never require Home |
| GameController and raw HID writing to the same pad | Flicker or conflicting lights/rumble | One output owner per feature |
| Wine controller options change between releases; Gcenx's SDL build is unknown | Windows controller regressions | Version-gated settings, SDL pre-flight probe, nightly smoke test |
| DXVK-macOS is stale; Wine ecosystem churn | Breakage | Pinned URL + sha256, nightly smoke test, compat database |
| PS1 CD-ROM, SPU and GPU details take longer than planned | Schedule | Gated sub-milestones |

## 15. Items to verify before relying on them

**Build and platform**
1. Does `swift test` work with only the Command Line Tools?
2. Does `@Observable` compile with only the Command Line Tools?
3. Does a single-architecture `swift build` avoid XCBuild?
4. Are the Command Line Tools present on GitHub macOS runners?
5. Can GitHub's arm64 runners use Metal?

**Windows layer**
6. Gcenx tarball layout, MoltenVK, the bundled SDL2 version and its MFi flag, and the DXVK repack install method.
7. GPTK `.dmg` layout, its environment variables and **its license terms**.
8. Steam CEF flags under Wine.

**Firmware, licensing and test data**
9. The **OpenBIOS license**.
10. Whether Blargg and SingleStepTests data can be redistributed.
11. CGB palette table source.
12. MAP_JIT with ad-hoc signing.
13. CHD support: pure Swift vs libchdr. This is your decision, at M6i.

**Controllers**
14. Wired Xbox: GameController rumble/Share on macOS 26.2+/27, the HID output-report `0x01` rumble, paddles over USB, and the Adaptive Controller over USB.
15. Edge paddles/Fn in `physicalInputProfile`.
16. DualSense `light.color` and `playerIndex` LEDs.
17. `supportedLocalities` for each pad and connection type, and the trigger side swap.
18. `GCMotion` axes, signs and rate per pad, and whether GameController applies its own stick deadzone.
19. Input Monitoring behaviour for gamepad-only HID, the USB approval prompt, and whether grants survive ad-hoc rebuilds.
20. Programmatic Quadraphonic switching for USB HD haptics.
21. `GCControllerHomeButtonSettingsManager` on macOS 27.
22. Boktai pin roles and LUX table, GBA gyro/tilt scales, and the GunCon constants.
23. Whether a Wine child honours System Settings remapping, and whether environment variables reach `winedevice.exe`.
24. Whether the Info.plist remapping keys work for non-App-Store apps.

## 16. Verification, end to end
- **Every push:**
  - Linux CI builds the cores and ControllerModel, then runs `swift test`, `rom-test --all`, the HID parser fixtures, the controller trace replays and the pad-protocol goldens. Any `pass → fail` change fails CI.
  - macOS CI builds `Attic.app` and runs `--self-test`.
  - The `clt-only` job proves the build works without Xcode.
- **Per milestone:** each exit criterion in §11 is either automated or a short manual checklist in `docs/`.
- **Controllers:** `controller-dump` output from your pads is checked into `Tests/Fixtures/hid/`. The manual hardware matrix in §8.7 is run and signed off at M2, M4 and M7.
- **Windows:** the nightly `engines-smoke` job plus the controller probe `.exe` files. D3DMetal checks run locally with your own GPTK.

## 17. First execution step after approval
1. **Repo setup.** In `/home/user/Port-Windows` on `claude/dreamy-cerf-k06c54`, build **M0**: Package.swift, empty modules (including ControllerModel/ControllerKit), the build script, Info.plist with the controller keys, entitlements, CI, README/LEGAL/DUMPING/CONTROLLERS, `controller-dump`.
2. **Start M1.** EmulatorKit, ControllerModel's pipeline and mailboxes, then the GBCore CPU and bus, then `rom-test`.
3. **Swift for local testing.** This container has no Swift toolchain. I'll try to install the swift.org Linux toolchain to build and test the pure-Swift modules here; otherwise CI is the source of truth.
4. **Publish.** Commit, push, and open a **draft PR**, then watch CI and fix any failures.
