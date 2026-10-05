# Maintain a personal Flux installation

[Documentation index](README.md)

This workflow builds and installs your checkout locally. It does not publish a release,
upload a package to AUR, or push your branch. The installed desktop package and Android app
replace your normal Flux installation, not a parallel test installation.

## Fix and validate

1. Work on your maintained branch, currently `feat/herdr-interactive-control`.
2. Inspect `git status --short` and reproduce the problem before changing code.
3. Apply the fix and run the relevant checks in [Development](development.md).
4. Commit the settled fix using a Conventional Commit, then rebuild the affected component.

Keep signing credentials and local Android SDK configuration out of Git. The local
`android/app/build.gradle.kts` change adds `.dev` and the Flux Test name to debug builds;
release builds still use `org.omarchy.flux` and the Flux name. Do not accidentally commit
that debug-only customization with a fix.

Rebuild the desktop for daemon/CLI/Qt/plugin changes, Android for phone changes, and both
for changes that require a new protocol capability on both sides.

## Update the PC

Build and install the complete Arch package from the checkout as your regular user:

```sh
cd /path/to/flux/dist/arch
makepkg -sif
```

The build runs the package's Go checks. Installation asks for sudo and replaces the existing
`omarchy-flux` package, even when you rebuild the same version. Do not uninstall it first,
and do not run `sudo make install` over pacman-owned files.

After a successful installation:

```sh
systemctl --user daemon-reload
systemctl --user restart fluxd.service
/usr/bin/flux-cli version
/usr/bin/flux-cli doctor
```

Use `/usr/bin/flux-cli` here: your shell may otherwise find `bin/flux-cli` from the checkout.
Do not delete `~/.config/flux` or `~/.local/share/flux`; they hold configuration and identity.
Run `/usr/bin/flux-cli setup` if setup is missing or changed, not to reset your installation.

The package version includes the nearest release tag, commit count, and Git revision.
`makepkg` also updates the `pkgver` line of `dist/arch/PKGBUILD`. Review this generated change;
do not include it in a source fix merely because you built the package.

A newer upstream package can replace your personal build during a system/AUR update.
Review those transactions. If you choose to exclude `omarchy-flux` from updates, you become
responsible for incorporating upstream fixes yourself. `flux-cli update` also installs the
upstream release, not your branch; use this rebuild workflow for your personal version.

## Update Android without losing data

Your personal release uses:

- Package ID: `org.omarchy.flux`.
- Keystore: `~/.local/share/flux-personal/android-release.p12`.
- Key alias: `flux-personal`.
- Password file: `~/.local/share/flux-personal/signing-password.txt`.

These files were created locally during the first migration. Back up the entire directory
securely. Never regenerate the key for an update, commit it, or publish its password.
Without the same signing key, Android cannot update your app while preserving its data.

Set `ANDROID_HOME` to your installed SDK and connect the phone with USB debugging enabled.
Run `adb devices` to confirm it is authorized. With multiple phones, set `ANDROID_SERIAL`
to the intended device; the following commands use that selection.

### 1. Choose a higher version code and build

The first personal installation used version code `1400037`. Read the currently installed
code before every update:

```sh
"$ANDROID_HOME/platform-tools/adb" shell dumpsys package org.omarchy.flux |
  grep -E 'versionCode=|versionName='
```

Choose a code greater than the installed one: `1400038` for the first update, then `1400039`,
and so on. This counter is independent of Git revisions and must not decrease after a rebase.
The example assumes that no release-signing environment variables are set, so Gradle builds
an unsigned release and signing happens separately:

```sh
cd /path/to/flux/android
export FLUX_VERSION_CODE=1400038
export FLUX_VERSION="0.14.0-personal.$FLUX_VERSION_CODE.g$(git rev-parse --short HEAD)"
./gradlew :app:assembleRelease --no-daemon --no-configuration-cache --console=plain
```

The name is informational; the version code controls upgrade ordering. Update the base
version in the name when appropriate. Use a new code even when rebuilding the same commit.
The assemble task is not a substitute for the relevant unit tests and lint checks.

### 2. Sign and verify

From `android/`, use the installed Build Tools version; `36.0.0` was used for the first build:

```sh
TOOLS="$ANDROID_HOME/build-tools/36.0.0"
KEYS="$HOME/.local/share/flux-personal"
APK="app/build/outputs/apk/release/flux-personal.apk"

"$TOOLS/apksigner" sign \
  --ks "$KEYS/android-release.p12" \
  --ks-key-alias flux-personal \
  --ks-pass "file:$KEYS/signing-password.txt" \
  --out "$APK" \
  app/build/outputs/apk/release/app-release-unsigned.apk

"$TOOLS/apksigner" verify --verbose --print-certs "$APK"
"$TOOLS/aapt" dump badging "$APK" | head -1
```

Proceed only after signing and verification succeed. Confirm the package ID and the new
version code. The PKCS12 key uses the store password, so no separate `--key-pass` is needed.

### 3. Install as an update

```sh
"$ANDROID_HOME/platform-tools/adb" install -r "$APK"
"$ANDROID_HOME/platform-tools/adb" shell am force-stop org.omarchy.flux
"$ANDROID_HOME/platform-tools/adb" shell am start \
  -n org.omarchy.flux/org.omarchy.flux.ui.MainActivity
```

Do not uninstall first and do not clear app data. Updating with the same package ID and
signing key preserves identity, settings, and pairing. A signature mismatch is a reason to
stop and check which key/app you used, not to uninstall automatically.

The first switch from the upstream APK required an uninstall because its signature differed.
Future personal updates do not. Returning to the upstream APK would require another signing
migration and normally another uninstall.

## Incorporate upstream changes

Start with settled commits and a clean working tree. Preserve local-only changes separately
before rebasing and restore them afterward; do not discard them to make Git accept a rebase.

```sh
git fetch upstream
git rebase upstream/master
```

Resolve any conflicts, stage only the resolved files, and run `git rebase --continue`.
Re-run the relevant checks, then update the installed components with the steps above.
Rebasing changes commit IDs but must not reset Android's version-code counter or signing key.

No push is required for a local installation. If you deliberately update your remote branch
after rebasing, use `--force-with-lease` rather than an unconditional force push.

## When something breaks

- PC: inspect `journalctl --user -u fluxd.service -n 100 --no-pager` and `flux-cli doctor`.
- Android: inspect `adb logcat` and confirm the installed version in About Flux.
- Keep a known-working package/APK before replacing it; filenames such as `flux-personal.apk`
  are reused by later builds. Do not commit binary backups.
- To restore older Android source safely, rebuild that revision with the same signing key
  and a higher version code. Do not uninstall merely to bypass downgrade protection.
- Confirm ordinary usage and the fixed behavior after installation, not just build success.
