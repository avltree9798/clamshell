# Clamshell

A Nintendo DS emulator for iPhone and iPad, written in Swift and SwiftUI, built
around iPhone Duo: hold it half-open and turned sideways, and it plays like a DS,
with the top screen above the fold and the touch screen below it. 3DS support is
planned as a second core.

Clamshell is free software under the GPLv3. You can build it yourself for free;
the App Store version costs £5 and pays for development.

> **Status: early development (milestone M0/M1).** The ARM9 and ARM7 interpreters,
> memory map, timers, DMA, IPC, math unit, cartridge reads, touch input and an HLE
> BIOS are written. The 2D and 3D graphics engines, sound and save memory are not
> yet, so commercial games do not run. See the [spec](docs/SPEC.md) for the plan.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/EmuKit` | The contract between cores and the app: `EmulatorCore`, frame/audio/input channels, save-state format, scheduler |
| `Sources/NDSCore` | The DS core: CPUs, buses, hardware, HLE BIOS, direct boot |
| `Sources/CTRCore` | The 3DS core (placeholder until milestone M6) |
| `Sources/ClamshellBench` | The M0 interpreter benchmark |
| `App/Clamshell` | The SwiftUI app: library, game view, layouts, Metal presenter, audio, controllers |
| `Tests` | Swift Testing suites for EmuKit and the DS core |

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
