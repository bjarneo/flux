# Flux for Windows

The Windows app of Flux. It connects a Windows computer to an Omarchy computer that runs `fluxd`, as the Mac app does.

- `FluxKit/`: the core library. It has no UI and runs on Linux and Windows.
- `FluxKit.Tests/`: the tests of the core, with tests against a headless `fluxd`.
- `Flux/`: the WPF app.
- `Flux.UiTests/`: builds each page of the app with sample computers. It runs only on Windows.

[Flux for Windows](../docs/windows.md) tells how to build, test, and pair the app, and lists its features.

The first Windows preview came from [PR #92](https://github.com/bjarneo/flux/pull/92). Its discovery cache, TLS key rules, and file name rules live on in FluxKit.
