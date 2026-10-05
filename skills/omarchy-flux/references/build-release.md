# Build and release reference

## Requirements

- Arch Linux or Omarchy for the desktop package.
- Go 1.27.1 or later, CMake 3.21 or later, Ninja, and a C++20 compiler.
- Qt 6.5 or later with Qt Quick, SVG, and Wayland support.
- JDK 21 and Android SDK platform 36 for Android.
- Android Build Tools 36.0.0 and the committed Gradle wrapper.
- Xcode and XcodeGen on macOS 14 or later for the macOS app, and Xcode 26 or later for the iOS app.

Use `docs/install.md` for the full Arch dependency command.
Use `docs/android.md` for SDK setup and phone installation.
Use `docs/macos.md` for the macOS app build and pairing.
Use `docs/ios.md` for the iOS app build, installation, and pairing.

## Desktop builds

From the repository root:

```sh
make build test vet
make build VERSION=0.1.0
make snapshot
```

Outputs:

- `bin/flux-cli`
- `bin/fluxd`
- `bin/flux-approve`
- `gui/app/build/flux-gui`

The PAM helper is static.
The same version reaches the Go binaries and Qt host.

To install the complete package from the checkout:

```sh
cd dist/arch
makepkg -si
flux-cli setup
flux-cli doctor
```

Run `makepkg` as a regular user.
Its package function uses `DESTDIR`, so the build does not run live system setup.
Pacman runs the install hook after installation.

The package installs the CLI as `/usr/bin/flux-cli`.
It must not install `/usr/bin/flux`, because the `fluxcd` package owns that path.
The short name `flux` is the link `/usr/lib/flux/bin/flux`.
`/etc/profile.d/flux-path.sh` adds that directory to the end of `PATH`.
Call `flux-cli` in desktop entries, key bindings, menu actions, and printed hints.

For a user-only install:

```sh
make build
make install-user
export PATH="$HOME/.local/bin:$PATH"
flux-cli setup --no-plugin
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
The release workflow sets the code to `(MAJOR * 1000000 + MINOR * 1000 + PATCH) * 100` from the tag.
The release workflow builds the APK without a signature, then signs it with `apksigner` in a job without Gradle.
Keep the release key for upgrades.

Disable the Gradle configuration cache for builds that use release secrets:

```sh
./gradlew :app:assembleRelease --no-daemon --no-configuration-cache
```

## Workflows

| File | Trigger and result |
| --- | --- |
| `.github/workflows/build.yml` | Push to `master`, manual run, or reusable call. Builds the Arch package, the Android APKs, and the macOS app, and tests the iOS app. Pull requests run no build. |
| `.github/workflows/release.yml` | Stable version tag or manual rebuild of an existing tag. Publishes the package, signed APK, AUR recipe, certificate details, checksums, and the signature of the checksums. |
| `.github/workflows/aur.yml` | Reusable call after a successful release. Pushes the tested recipe to AUR. |

`flux-cli update` and `fluxd` find the release assets by name: `omarchy-flux-VERSION-PKGREL-ARCH.pkg.tar.zst`, `flux-android-VERSION.apk`, `SHA256SUMS`, and `SHA256SUMS.sig`.
Keep these names when you change `release.yml`.
Use the upgrade check in `docs/releasing.md` after each release.

Release tags use `vMAJOR.MINOR.PATCH`.
Prerelease tags do not pass release validation.
Manual release runs require an existing tag and build that exact tag.

The package contains the CLI, daemon, Qt host, plugin, helper, desktop files, service, and udev rule.
CI currently builds the binary package for `x86_64`.
The source recipe also declares `aarch64`, which needs a native build and separate verification.

## Release signing

The `sign` job of `release.yml` signs `SHA256SUMS` with an Ed25519 key and publishes `SHA256SUMS.sig`.
`flux-cli update` and `fluxd` check the signature with `PublicKey` in `internal/release/sign.go`, then check each download against `SHA256SUMS`.
While `PublicKey` is empty, they check only `SHA256SUMS` and log that.
After `PublicKey` is set, they refuse a release without a valid `SHA256SUMS.sig`.

To set up the key, do these steps in this order:

1. Make the key pair outside the repository:

   ```sh
   mkdir -p "$HOME/.local/share/flux-release"
   go run ./scripts/signsums keygen "$HOME/.local/share/flux-release/release-signing.key"
   ```

   The command writes the private key to the file and prints the public key.

2. Set the private key as the `RELEASE_SIGNING_KEY` secret of the `release` environment:

   ```sh
   gh secret set RELEASE_SIGNING_KEY --env release < "$HOME/.local/share/flux-release/release-signing.key"
   ```

3. Publish a release, and check its signature with the public key:

   ```sh
   dir=$(mktemp -d)
   gh release download v0.1.0 -D "$dir" -p 'SHA256SUMS*'
   go run ./scripts/signsums verify "$dir/SHA256SUMS" PUBLIC_KEY
   ```

4. Set `PublicKey` in `internal/release/sign.go` to the public key, and release that change.

Keep the secret and a backup of the private key after step 4.
Without the key, the installed copies cannot update themselves.
Do not make a key, set a secret, or publish a release unless the user asks for that action.
Read the release signing key section of `docs/releasing.md` for the details.

## Repository setup

Read `docs/releasing.md` for the complete procedure.
The jobs that use secrets run in the GitHub environment `release`.
Set each secret in that environment, for example `gh secret set KEYSTORE_PASSWORD --env release`.

Release signing secret:

- `RELEASE_SIGNING_KEY`

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

The source uses the MIT license in `LICENSE`.
The PKGBUILD sets `license=('MIT')` and installs `LICENSE` in `/usr/share/licenses/omarchy-flux/`.
Do not change the license terms. Do not add maintainer personal details.

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
