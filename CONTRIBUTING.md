# Contributing

1. Sign the [CLA](CLA.md) in your first pull request.
2. Write from public documentation (GBATEK, 3DBrew, the ARM Architecture
   Reference Manual). Reading other emulators to understand behaviour is fine;
   copying their code is not, because it would stop the App Store build.
3. Never commit games, BIOS, firmware or keys, not even in tests. Tests use
   generated images such as `SyntheticROM` or homebrew test suites with a
   licence that allows it.
4. Keep the cores free of Apple frameworks, so they build and test on Linux.
5. Performance matters in `NDSCore`: no Swift arrays, existentials or closures in
   the CPU loop. Run `swift run -c release clamshell-bench` before and after a
   change to a hot path, and say the numbers in the pull request.
6. `swift test` must pass.
