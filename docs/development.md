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

## Agent answers end to end

The harness in `android/tools/` tests the answer to an agent from the phone without a real agent.
`fake_herdr.py` is a fake herdr server with 1 blocked agent.
`timed_answer.py` taps an action of the notification on the emulator and measures the time until herdr gets the input.
The harness uses Python 3, `adb`, and the Android SDK tools.
It reads no logcat.

To run the unit tests of the harness:

```sh
python3 -m unittest discover -s android/tools -p 'test_*.py'
```

### The fake herdr

```sh
python3 android/tools/fake_herdr.py --socket SOCKET --scenario codex3 \
  --control CONTROL.json --log SENDS.jsonl
```

The fake serves the herdr API of protocol 22 on `SOCKET`.
The path of `SOCKET` must be shorter than 108 bytes.
It never connects to another herdr, so it does not touch your own herdr session.

| Scenario | Agent | Dialog |
| --- | --- | --- |
| `codex3` | codex | 3 numbered choices |
| `freetext` | claude | A question that needs free text, with no choices |
| `choices4` | claude | 4 numbered choices |
| `opencode` | opencode | A menu row that opencode moves with the arrow keys |

The control file is a JSON object.
The fake reads it every 50 ms.
Write it in 1 step with a rename.
All fields are optional.

| Field | Value |
| --- | --- |
| `status` | `idle`, `working`, `blocked`, or `done` |
| `scenario` | A scenario name |
| `question` | The question line of the dialog. `null` restores the default. |

A change sends a `pane_agent_status_changed` event to each subscription.
The phone reads the output of an agent again only after a status change.
To change the scenario, write `working`, and then write `blocked` with the new `scenario`.
The agent shows its dialog only while the status is `blocked`.
With `--after-send working`, the default, a send call to a blocked agent sets the status to `working`.
With `--after-send keep`, the status stays.

The log has 1 JSON line for each send call: `agent.send_keys`, `agent.prompt`, and `pane.send_input`.
Each line has `time_ms`, the host time in milliseconds, `method`, `params`, and `result`.
The `result` is `ok` or the error code, for example `agent_blocked`.

### The test setup

A test `fluxd` that is not headless follows herdr.
Run it, the fake herdr, the emulator, and a private `adb` server in 1 user and network namespace.
Use your own folder and your own ports.
The commands below use these values:

```sh
export MISE_GO_VERSION=1.27.1
E=$HOME/.cache/flux-e2e
mkdir -p "$E"/{config/flux,config/herdr,data,cache,run}
chmod 700 "$E/run"
printf 'herdr = true\nherdr_control = true\ncheck_updates = false\n' > "$E/config/flux/config.toml"
echo '{"status":"working"}' > "$E/control.json"
: > "$E/sends.jsonl"
```

1. Build `fluxd` and the debug app:

   ```sh
   make build-go
   cd android && ./gradlew :app:assembleDebug --no-daemon && cd ..
   ```

2. Start the namespace. The holder process keeps it open. Save its PID:

   ```sh
   unshare --user --map-root-user --net sleep 36000 &
   NS=$!
   IN="nsenter -t $NS -U -n --preserve-credentials --"
   $IN ip link set lo up
   ```

3. Start the fake herdr in the namespace. It must run there, because `fluxd` checks the user of the herdr socket:

   ```sh
   $IN python3 android/tools/fake_herdr.py --socket "$E/config/herdr/herdr.sock" \
     --scenario codex3 --control "$E/control.json" --log "$E/sends.jsonl" &
   ```

4. Start the test `fluxd` with a scrubbed environment. `PATH` has no herdr CLI and no agent launcher. The environment has no `DBUS_SESSION_BUS_ADDRESS`, `WAYLAND_DISPLAY`, `DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, or `HERDR_SOCKET_PATH`:

   ```sh
   $IN env -i PATH=/usr/bin:/bin HOME="$E" XDG_CONFIG_HOME="$E/config" XDG_DATA_HOME="$E/data" \
     XDG_CACHE_HOME="$E/cache" XDG_RUNTIME_DIR="$E/run" FLUX_SOCKET="$E/run/flux/fluxd.sock" \
     bin/fluxd -udp-port 12100 -tcp-port 28720 &
   ```

5. Start the emulator and a private `adb` server in the namespace. Run the emulator under the emulator lock. Set `ANDROID_SERIAL`:

   ```sh
   export ADB_USB=0 ADB_MDNS=0 ANDROID_ADB_SERVER_PORT=28738 ANDROID_SERIAL=emulator-5554
   $IN flock ~/.cache/flux-emulator.lock emulator -avd Pixel_6_API_36 -no-window -no-audio \
     -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect &
   $IN adb wait-for-device
   $IN adb shell 'while [ -z "$(getprop sys.boot_completed)" ]; do sleep 1; done'
   $IN adb install -r android/app/build/outputs/apk/debug/app-debug.apk
   ```

6. Forward the TCP ports 12070 to 12108 of the phone to the emulator, with `adb forward`, as in the [Android tools](android.md#test). Open Flux on the emulator. Pair with the test `fluxd`:

   ```sh
   (sleep 3; printf 'y\n'; sleep 40) | $IN script -q -c \
     "env XDG_RUNTIME_DIR=$E/run FLUX_SOCKET=$E/run/flux/fluxd.sock bin/flux-cli pair NAME" /dev/null
   ```

   Tap **Pair** on the emulator. Then turn on **Agent control** on the Access card of the computer.

7. Check that `fluxd` follows the fake. The agent list must show the blocked codex agent after you write `{"status":"blocked"}` to the control file:

   ```sh
   $IN env XDG_RUNTIME_DIR="$E/run" FLUX_SOCKET="$E/run/flux/fluxd.sock" bin/flux-cli status --json
   ```

To stop the setup, stop only the PIDs that you started.
Stop the emulator with `adb emu kill`.
Do not stop a process by a name pattern.

### The timed test

The timed test checks that herdr gets a choice 2 s or less after the tap.
It does 10 runs.
In each run, it sets the agent to `blocked`, waits for the notification with actions, taps the action, and reads the send time from the log.
It stops when `ANDROID_SERIAL` is not set or is not an emulator, because it taps the screen.

```sh
python3 android/tools/timed_answer.py --runs 10 --fake-log "$E/sends.jsonl" \
  --control "$E/control.json" --action '^Yes, proceed' --expect send_keys:1 --pin 1234 --out "$E/timed.md"
```

The script prints 1 Markdown row for each run.
The columns are the taps, the seconds from the status change to the notification, the seconds from the tap to the input at herdr, and the send that herdr got.
The script exits with 1 when a run is slower than `--limit` seconds, which is 2 by default, or when a run fails.
`--pin` is the PIN of the emulator. The script keeps the screen on and dismisses the lock screen with it.

The time from the tap includes the start of the `input` command on the phone, so it is longer than the time of a finger.
The time to the notification has the poll interval of about 0.2 s as its error.
The harness takes no time for the lock prompt of the app, so unlock before the run.
The app asks for the phone lock before the first answer, and the unlock stays valid for 5 minutes.
Answer once by hand before a run that checks the current app.

| Option | Use |
| --- | --- |
| `--no-tap` | Measure only the time to the notification. This works with an app that has no actions in its notification. |
| `--screen` | Tap a node of the open screen of the app, for example the **Yes, proceed** key of the dock, in place of a notification action. The first time is then the time until that node shows. |
| `--scenario NAME` | Set a scenario of the fake herdr for each run. |
| `--action REGEX` | The text of the action to tap. The default is `^yes`. In the notification, the script taps only a button, so the expanded text of the notification never matches. Anchor the pattern with `^` for the screen mode. |
| `--expect SEND` | The send that herdr must get, for example `send_keys:1`. |

## Update xterm.js

The live terminal of Flux for Android draws with xterm.js from the npm package `@xterm/xterm`.
The app keeps 3 files of the package in `android/app/src/main/assets/terminal/`:

| File in the app | File in the package |
| --- | --- |
| `xterm.js` | `lib/xterm.js` |
| `xterm.css` | `css/xterm.css` |
| `xterm-LICENSE.txt` | `LICENSE` |

The comment at the top of `index.html` names the version that the app uses.

To update xterm.js:

1. Set `VERSION` to the new version. This command gets the newest version from the registry:

   ```sh
   VERSION=$(npm view @xterm/xterm version)
   ```

2. From the repository root, download the package into a temporary folder:

   ```sh
   REPO=$PWD
   cd "$(mktemp -d)"
   npm pack "@xterm/xterm@$VERSION"
   ```

3. Compare the checksum of the archive with the checksum of the registry. The 2 lines must be the same:

   ```sh
   npm view "@xterm/xterm@$VERSION" dist.integrity
   echo "sha512-$(openssl dgst -sha512 -binary "xterm-xterm-$VERSION.tgz" | base64 -w0)"
   ```

4. Copy the 3 files into the app:

   ```sh
   tar -xzf "xterm-xterm-$VERSION.tgz"
   cp package/lib/xterm.js package/css/xterm.css "$REPO/android/app/src/main/assets/terminal/"
   cp package/LICENSE "$REPO/android/app/src/main/assets/terminal/xterm-LICENSE.txt"
   ```

5. Change the version in the comment at the top of `index.html`.
6. Make sure that `xterm.js` still has the class names `xterm-accessibility` and `live-region`. The output must show the 2 names:

   ```sh
   grep -oE 'xterm-accessibility|live-region' "$REPO/android/app/src/main/assets/terminal/xterm.js" | sort -u
   ```

   `index.html` uses these names so that TalkBack does not read each frame. If a name changed, change `index.html` too.
7. Run the [Android checks](#android-checks).
8. Open **Live** on a phone and check the terminal.
9. Turn on TalkBack on the phone.
10. Open **Live** again. TalkBack must not read each new frame aloud.

Do not change the copied files, so that each file stays the same as the file in the package.
A reviewer can then compare each file with the package.
`xterm.js` ends with a `sourceMappingURL` comment, and the app does not include the map file.

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
