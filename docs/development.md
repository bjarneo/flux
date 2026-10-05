# Development

[Documentation index](README.md)

Install the [desktop dependencies](install.md#build-and-install-directly) and [Android tools](android.md#build-and-install) first.
Run commands from the repository root unless a section changes the directory.

## Desktop checks

```sh
make build test vet
```

The build creates the Go CLI, daemon, static approval helper, and Qt app.
The tests use the Go race detector and include the two-daemon end-to-end test.
The vet target runs `go vet` and lists files that need `gofmt`.
Successful formatting produces no filenames.

To build only one desktop component:

```sh
make build-go
make build-gui
```

To set the version in all desktop binaries:

```sh
make build VERSION=0.1.0
```

## Run from the checkout

`make dev` starts the daemon in the foreground with your normal Flux data paths.
Stop an existing daemon first, or use the isolated environment below.
`make open` builds the desktop and opens its selected host.

```sh
make dev
```

In another terminal:

```sh
make open
```

To force the native Qt host and load QML from disk:

```sh
FLUX_QML_DIR="$PWD/gui/qml" gui/app/build/flux-gui
```

Keep shared views compatible with both hosts.
See [shared QML](qml.md) and [Omarchy integration](omarchy.md).

## Isolated daemon

Use temporary XDG paths to keep test identity and settings separate from your desktop session:

```sh
TEST_ROOT=$(mktemp -d)
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_DATA_HOME="$TEST_ROOT/data"
export XDG_CACHE_HOME="$TEST_ROOT/cache"
export XDG_RUNTIME_DIR="$TEST_ROOT/run"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export FLUX_SOCKET="$XDG_RUNTIME_DIR/flux/fluxd.sock"
./bin/fluxd -headless -udp-port 28716 -tcp-port 28720
```

Headless mode disables desktop integration and limits discovery to loopback.
It still creates its own local identity and settings.
Use the same `FLUX_SOCKET` value for a CLI in another terminal.
Stop the daemon before you remove the temporary directory.

## UI checks

```sh
make snapshot test-gui
```

The Qt host renders fixture screens into `snapshots/`.
`make test-gui` runs the [QML view tests](qml.md#view-tests) with the mock backend.
The [QML guide](qml.md#snapshot-harness) covers theme and screen filters.
The [shell guide](omarchy.md#offscreen-test) covers an isolated plugin host.

## Android checks

```sh
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease --no-daemon
```

The unit tests cover protocol, approval messages, capture plans, streams, camera geometry, the herdr alerts, colors, and replies, and the dictation text rules.
The release build runs R8 and checks release-only build errors.
Without release credentials, it produces an unsigned APK.
See [Android tools](android.md#test) for a test peer and phone screenshots.

## macOS checks

```sh
make test-macos macos
```

The tests cover packets, certificates, the verification key, and the wire formats and logic of each feature.
See [Flux for macOS](macos.md#test-against-a-computer-on-the-same-mac) to test the app against a local `fluxd`.

## iOS checks

```sh
make ios test-ios ios-release
```

The build must show no warnings in `ios/`.
`make test-ios` runs the app tests and the FluxKit tests in an iPhone simulator.
`make ios-release` builds the app for iPhones in Release without signing, in `ios/build/Build/Products/Release-iphoneos`.
It shows the errors that only the optimized build has, like the Android release build.
A change in FluxKit needs both `make test-macos` and `make test-ios`, because the two platforms compile different code.
See [Flux for iOS](ios.md#local-tests) for the simulator and the device checks.

The `ios` job in `build.yml` also runs `make ios-release`.
Then it checks that the built `Info.plist` has a text for each permission and lists `_flux._udp`.
It also checks that the app and the share extension each contain `PrivacyInfo.xcprivacy`.

Pull requests run no build, to save GitHub minutes.
Each push to `master` runs all jobs, and macOS runners use the minutes at a high rate.
To build and test a branch before the merge, start a manual run:

```sh
gh workflow run build.yml --ref BRANCH
```

## Package and workflow checks

```sh
bash -n dist/arch/PKGBUILD dist/arch/omarchy-flux.install
sh -n dist/post-install.sh dist/pre-remove.sh
actionlint
python3 -m unittest discover -s scripts -p 'test_*.py'
```

To build the local package without installation:

```sh
cd dist/arch
makepkg --force
makepkg --printsrcinfo
```

The package check function runs the Go tests and vet checks.
The [release guide](releasing.md) covers the archive-based AUR recipe.

## Change checklist

| Change | Required check |
| --- | --- |
| Go CLI or daemon | `make test vet` and the relevant package tests |
| Shared QML or host | `make build-gui snapshot test-gui` and both host contracts |
| Android | JVM tests, lint, debug build, and release build |
| macOS | `make test-macos macos`, then a run against `fluxd` |
| iOS | `make ios test-ios ios-release`, then a run in the simulator against `fluxd` |
| Protocol | Go, Kotlin, and Swift tests, plus the two-daemon end-to-end test |
| Approval | Read `docs/approve.md`, then run the Go and Android approval tests. For a change in FluxKit or the Apple apps, also run the Swift approval tests `ApproveMessageTests`, `ApprovePluginLogicTests`, `ApproveKeysBackupTests`, and the iOS `ApproveLogicTests` with `make test-macos test-ios`. They run only on a Mac or in the `macos` and `ios` jobs of CI. |
| Package or workflow | Shell syntax, `actionlint`, package build, and release-generator tests |

Flux uses the [MIT license](../LICENSE).
Only the source owner changes the license.
