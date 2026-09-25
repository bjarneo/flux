# Build and release reference

## Requirements

- Arch Linux or Omarchy for the desktop package.
- Go 1.27.1 or later, CMake 3.21 or later, Ninja, and a C++20 compiler.
- Qt 6.5 or later with Qt Quick, SVG, and Wayland support.
- JDK 21 and Android SDK platform 36 for Android.
- Android Build Tools 36.0.0 and the committed Gradle wrapper.

Use `docs/install.md` for the full Arch dependency command.
Use `docs/android.md` for SDK setup and phone installation.

## Desktop builds

From the repository root:

```sh
make build test vet
make build VERSION=0.1.0
make snapshot
```

Outputs:

- `bin/flux`
- `bin/fluxd`
- `bin/flux-approve`
- `gui/app/build/flux-gui`

The PAM helper is static.
The same version reaches the Go binaries and Qt host.

To install the complete package from the checkout:

```sh
cd dist/arch
makepkg -si
flux setup
flux doctor
```

Run `makepkg` as a regular user.
Its package function uses `DESTDIR`, so the build does not run live system setup.
Pacman runs the install hook after installation.

For a user-only install:

```sh
make build
make install-user
export PATH="$HOME/.local/bin:$PATH"
flux setup --no-plugin
```

To add the plugin from that checkout, run `make install-plugin` and follow its printed shell commands.
The user-only install omits the root PAM helper and webcam system setup.

## Android builds

From `android/`:

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease --no-daemon
```

Without signing variables, the release APK remains unsigned.
Its path is `app/build/outputs/apk/release/app-release-unsigned.apk`.
The debug APK is `app/build/outputs/apk/debug/app-debug.apk`.

Signed builds need all four variables:

- `KEYSTORE_FILE`, an absolute path or a path relative to `android/`.
- `KEYSTORE_PASSWORD`.
- `KEY_ALIAS`.
- `KEY_PASSWORD`.

`FLUX_VERSION` sets `versionName`.
`FLUX_VERSION_CODE` sets a positive Android version code.
The release workflow uses `github.run_number` for the code.
Preserve the workflow's version-code sequence and the release key for upgrades.

Disable the Gradle configuration cache for builds that use release secrets:

```sh
./gradlew :app:assembleRelease --no-daemon --no-configuration-cache
```

## Workflows

| File | Trigger and result |
| --- | --- |
| `.github/workflows/build.yml` | Main branch, pull request, manual run, or reusable call. Builds the Arch package and Android APKs. |
| `.github/workflows/release.yml` | Stable version tag or manual rebuild of an existing tag. Publishes the package, signed APK, AUR recipe, certificate details, and checksums. |
| `.github/workflows/aur.yml` | Reusable call after a successful release. Pushes the tested recipe to AUR. |

Release tags use `vMAJOR.MINOR.PATCH`.
Prerelease tags do not pass release validation.
Manual release runs require an existing tag and build that exact tag.

The package contains the CLI, daemon, Qt host, plugin, helper, desktop files, service, and udev rule.
CI currently builds the binary package for `x86_64`.
The source recipe also declares `aarch64`, which needs a native build and separate verification.

## Repository setup

Read `docs/releasing.md` for the complete procedure.

Android secrets:

- `KEYSTORE_BASE64`
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`

AUR secrets:

- `AUR_SSH_PRIVATE_KEY`
- `AUR_USERNAME`
- `AUR_EMAIL`
- `AUR_KNOWN_HOSTS`

Set the `AUR_PUBLISH` repository variable to `true` to enable the AUR job.
The AUR account needs access to the `omarchy-flux` package repository.
Verify the AUR host key fingerprints before you store the known-hosts value.

The source has no selected license yet.
Keep the existing `LicenseRef-unknown` metadata until the owner selects a license.
Do not invent license terms or maintainer personal details.

## Prepare an AUR recipe

From the repository root, with `REPO` set to the actual GitHub repository:

```sh
python3 scripts/prepare-aur.py --tag v0.1.0 --repo "$REPO"
cd dist/aur
makepkg --printsrcinfo > .SRCINFO
makepkg
```

The script downloads the tag archive and calculates its SHA-256 checksum.
It reads the package recipe and install hook from that archive.
It retains the archive locally so `makepkg` can check and build the same bytes.
Use `--archive PATH` only for a local copy of the same GitHub archive or a local test.
Do not publish a recipe whose checksum comes from a different archive.

## Diagnose a release failure

- Tag failure: use a stable tag that exists on the remote.
- Missing secret: set the named secret and rerun the failed job.
- APK signature mismatch: compare `android-certificate.txt` with the previous release.
- AUR SSH failure: check the deploy key, package access, and verified known-hosts entry.
- AUR source failure: check the public archive URL and its checksum.
- Version-code downgrade: use a code above the installed release and preserve that sequence in CI.

A GitHub release can succeed while the later AUR job fails.
Rerun the failed AUR job after you fix its configuration.
