# Clamshell

A Nintendo DS emulator for iPhone and iPad, written in Swift and SwiftUI, built
around iPhone Duo: hold it half-open and turned sideways, and it plays like a DS,
with the top screen above the fold and the touch screen below it. A second core
runs Nintendo 3DS homebrew, and is growing towards games.

Clamshell is free software under the GPLv3. You can build it yourself for free;
the App Store version costs £5 and pays for development.

> **Status: early development (milestone M0/M1).** The ARM9 and ARM7 interpreters,
> memory map, timers, DMA, IPC, math unit, cartridge reads, touch input and an HLE
> BIOS are written. The 2D and 3D graphics engines, sound and save memory are not
> yet, so commercial games do not run. See the [spec](docs/SPEC.md) for the plan.
>
> **3DS:** the ARM11 interpreter (ARMv6K + VFPv2), an HLE Horizon kernel (threads,
> synchronisation, memory, ~40 SVCs), the srv, APT, cfg, ptm, hid and gsp::Gpu
> services and a .3dsx loader run 2D homebrew. Missing: the PICA200 3D GPU, DSP
> audio, the file system, and retail titles.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/EmuKit` | The contract between cores and the app: `EmulatorCore`, frame/audio/input channels, save-state format, scheduler |
| `Sources/ARMCore` | The ARM interpreter shared by both cores: ARM7TDMI, ARM946E-S and ARM11 MPCore with VFPv2 |
| `Sources/NDSCore` | The DS core: buses, hardware, HLE BIOS, direct boot |
| `Sources/CTRCore` | The 3DS core: address space, HLE kernel and services, .3dsx loader, framebuffer output |
| `Sources/ClamshellBench` | The interpreter benchmark for both consoles |
| `Tools` | Test programs built with clang: an ARM11 self-test and a 3DS homebrew |
| `App/Clamshell` | The SwiftUI app: library, game view, layouts, Metal presenter, audio, controllers |
| `Tests` | Swift Testing suites for EmuKit, the CPU and both cores |

## Building

Cores and tests build anywhere Swift 6 runs, including Linux:

```sh
swift test
swift run -c release clamshell-bench            # built-in workload
swift run -c release clamshell-bench game.nds   # your own dump
```

The iOS app needs Xcode 16 or later on a Mac:

```sh
brew install xcodegen
xcodegen                      # creates Clamshell.xcodeproj
open Clamshell.xcodeproj
```

Set your development team in the target's Signing settings to run it on a device.
With a free Apple account, builds expire after 7 days.

iPhone Duo's hinge APIs need the iOS 27.1 SDK. Add `CLAMSHELL_HINGE_API` to the
target's Active Compilation Conditions to turn on clamshell mode; without it the
app uses the regular phone and iPad layouts.

## Games, BIOS and firmware

Clamshell ships no Nintendo code and no games. Play only games you dumped from
cartridges you own. No BIOS or firmware is needed: the BIOS calls are
reimplemented in Swift and the firmware settings are generated.

## Contributing

Contributions need a signed [Contributor License Agreement](CLA.md), so the
project can keep publishing the App Store build. See [CONTRIBUTING.md](CONTRIBUTING.md).
Do not copy code from other emulators: write from public documentation such as
GBATEK and 3DBrew.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
