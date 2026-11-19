# Testing the Game Boy core

## What runs where
| Layer | Command | Needs ROMs? |
|---|---|---|
| Unit tests (hand-assembled ROMs: mappers, saves, RTC, rumble, joypad, timer, save-state determinism) | `swift test` | No |
| Framework-free checks | `swift run core-selftest` | No |
| ROM suites (acid2 images, Mooneye, optionally Blargg) | `scripts/fetch-test-roms.sh && swift run -c release rom-test --all` | Yes (downloaded, never committed) |

`scripts/fetch-test-roms.sh` verifies the SHA-256 of every download. By default it fetches only MIT-licensed suites (dmg-acid2, cgb-acid2, the Mooneye test suite). `--blargg` additionally fetches Blargg's ROMs, which have no explicit license, so CI does not use them.

## Pass criteria
* **Blargg:** text on the serial port ends in "Passed", or the cartridge-RAM signature `DE B0 61` at `$A001` with status `0` at `$A000`.
* **Mooneye:** the ROM executes `LD B,B`, then registers B,C,D,E,H,L must be 3,5,8,13,21,34.
* **acid2:** XXH64 of the final frame equals the value in `Tests/Manifests/gb.json`. Those values were checked pixel for pixel against the suites' reference images (dmg-acid2 compared by shade; cgb-acid2 compared by exact colour).
* **Determinism:** run N frames, save, then replay from the saved state on the same core and on a fresh core. The audio checksum and frame hash must match (`DeterminismTests`).

## Known failures
`Tests/Manifests/mooneye-known-fail.txt` lists every Mooneye test we fail, with the reason. Any other failure fails CI; a listed test that starts passing is reported so it can be removed from the list.

## Current results (M1)
* Blargg `cpu_instrs` 11/11, `instr_timing`, `mem_timing`, `mem_timing-2` pass; `halt_bug` passes (result is on screen only).
* dmg-acid2 and cgb-acid2 match their reference images exactly.
* Mooneye: 81 pass, 17 known failures (boot-ROM timing, fine PPU interrupt timing, MBC1 multicart, one timer edge case, CGB compatibility mode).

## Performance
`swift run -c release emu-bench gb <rom>` prints frames per second and the multiple of real time (native 59.73 fps). On a 2.8 GHz Xeon vCPU (a slow reference machine): about 35x real time for dmg-acid2 and 22x for the CPU-heavy cpu_instrs. The 30x target is for an Apple-silicon Mac and has not been measured there yet.
