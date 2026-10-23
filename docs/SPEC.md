# Spec

The full plan lives in the project's spec document:
https://claude.ai/artifact/HiPatRQK6XgX2oDJ2WVenf

Key decisions (October 23, 2026):

- v1 ships the DS only. `EmuKit` is designed against both systems, and `CTRCore`
  exists from day one, so 3DS can follow without rework.
- Swift and SwiftUI for the app. A core may move to C or C++ behind a Swift API if
  Swift misses the M0 benchmark (300 M guest instructions per second on A17 Pro).
- GPL-3.0-or-later with a CLA. Free to build from source; £5 on the App Store.
- No Nintendo code, keys, games or branding. HLE BIOS and generated firmware.

## Milestones

| Milestone | Exit criteria |
| --- | --- |
| M0 Spikes | Interpreter benchmark on device; clamshell prototype on a real iPhone Duo |
| M1 DS boots | Both CPUs, memory, DMA, timers, 2D engines, input; armwrestler passes |
| M2 DS complete | Software 3D, SPU audio, HLE BIOS, battery saves; 40 of 50 sample games playable |
| M3 DS app and beta | All layouts, lid close, save states, controllers, skins, iCloud; TestFlight |
| M4 App Store 1.0 | App Review passes |
| M5 DS polish | Metal compute 3D upscaling, rewind, cheats |
| M6 3DS research | HLE kernel, PICA200 on Metal; go/no-go speed test at month 15 |

## What exists now

Done: ARM9/ARM7 interpreters (ARM + Thumb, ARMv5TE extensions), memory map with
TCMs and WRAMCNT, timers, DMA (immediate, VBlank, HBlank, card), IPC sync and
FIFOs, divider and square root, cartridge data reads, touchscreen over SPI,
generated firmware, HLE BIOS (wait, halt, divide, square root, CpuSet, CRC16,
BitUnPack, LZ77, run-length), direct boot, VRAM framebuffer display mode, app
shell with library, layouts, Metal presenter, audio and controllers.

Next for M1: the 2D engines (backgrounds, sprites, windows, blending), VRAM bank
mapping, KEYCNT, RTC, and running armwrestler.
