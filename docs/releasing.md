# Release Flux

[Documentation index](README.md)

Stable tags build the complete desktop package and a signed Android APK.
The release workflow publishes both with an AUR recipe, certificate details, and SHA-256 checksums.
An optional final job pushes the tested recipe to AUR.

## Workflow map

| Workflow | Trigger | Result |
| --- | --- | --- |
| `build.yml` | Push to `master`, pull request, manual run, or reusable call | Arch package, Go tests, Android tests, lint, debug APK, and unsigned release build |
| `release.yml` | Push a `v*` tag or manually select an existing tag | Validated stable tag, tested desktop package, signed APK, and GitHub release |
| `aur.yml` | Reusable call after release publication | AUR commit with `PKGBUILD`, `.SRCINFO`, and the install hook |

The workflows live in [`.github/workflows/`](../.github/workflows/).
The AUR flow follows cliamp's source-package pattern.
The APK flow follows the persistent-key release pattern from kleeamp in `cliamp-mobile`.

## First release setup

1. Push this repository and the workflows to GitHub.
2. Use `master` as the default branch, or update the build workflow's branch filter.
3. Configure the Android secrets below.
4. Configure AUR access if you want automatic publication.
5. Select the source license before public distribution.

The repository currently has no selected license.
The package retains `LicenseRef-unknown` until the owner makes that choice.
Add the selected license file and update the package metadata together.

The release workflow accepts only stable `vMAJOR.MINOR.PATCH` tags, such as `v0.1.0`.
Prerelease tags fail validation.
The GitHub source archive must be public for AUR users to download it.

## Android release key

Create the key once, outside the repository:

```sh
mkdir -p "$HOME/.local/share/flux-release"
keytool -genkeypair \
  -keystore "$HOME/.local/share/flux-release/flux-release.jks" \
  -alias flux -keyalg RSA -keysize 4096 -validity 10000 \
  -dname 'CN=Flux Release'
```

Keep a backup of the keystore and its passwords.
Use the same key for every release so Android accepts app updates.

Set these repository secrets through GitHub settings or `gh secret set`:

| Secret | Value |
| --- | --- |
| `KEYSTORE_BASE64` | Base64-encoded keystore |
| `KEYSTORE_PASSWORD` | Keystore password |
| `KEY_ALIAS` | The key alias, such as `flux` |
| `KEY_PASSWORD` | Private-key password |

From the GitHub checkout:

```sh
base64 -w0 "$HOME/.local/share/flux-release/flux-release.jks" | gh secret set KEYSTORE_BASE64
gh secret set KEYSTORE_PASSWORD
gh secret set KEY_ALIAS
gh secret set KEY_PASSWORD
```

The workflow restores the keystore in the runner's temporary directory and removes it after the build.
It disables the Gradle configuration cache for the signed task.
The signature check rejects an APK signed with the Android debug certificate.
The release includes `android-certificate.txt` so you can compare certificate fingerprints across versions.

`FLUX_VERSION` sets Android `versionName` from the tag without `v`.
`FLUX_VERSION_CODE` uses the release workflow's run number.
A new workflow run increases that code, while a retry of the same run keeps it.
Preserve the code sequence if you move or replace the workflow.
An update needs the same certificate and a version code above the previously published release.

For a local signed build, set the four variables before the Gradle command:

```sh
export KEYSTORE_FILE="$HOME/.local/share/flux-release/flux-release.jks"
export KEY_ALIAS=flux
read -rsp 'Keystore password: ' KEYSTORE_PASSWORD
export KEYSTORE_PASSWORD
read -rsp 'Key password: ' KEY_PASSWORD
export KEY_PASSWORD
export FLUX_VERSION=0.1.0
export FLUX_VERSION_CODE=1
cd android
./gradlew :app:assembleRelease --no-daemon --no-configuration-cache
```

Use a code above the previous release when you distribute an update.
The output is `android/app/build/outputs/apk/release/app-release.apk` relative to the repository root.
Without signing variables, Gradle produces `app-release-unsigned.apk` instead.
Partial signing credentials stop the build.

## AUR setup

The package name is `omarchy-flux`.
The AUR account must own or co-maintain that package.
For a new package, its first valid push creates the AUR repository.

Set these repository secrets:

| Secret | Value |
| --- | --- |
| `AUR_SSH_PRIVATE_KEY` | Private key registered with the AUR account |
| `AUR_USERNAME` | Commit author name for AUR updates |
| `AUR_EMAIL` | Commit author email for AUR updates |
| `AUR_KNOWN_HOSTS` | Verified SSH known-hosts entry for `aur.archlinux.org` |

Obtain the host keys and compare their fingerprints with the [AUR SSH fingerprints](https://aur.archlinux.org/):

```sh
ssh-keyscan aur.archlinux.org > aur-known-hosts
ssh-keygen -lf aur-known-hosts
```

After you verify the fingerprints, set the secrets:

```sh
gh secret set AUR_SSH_PRIVATE_KEY < /path/to/aur-private-key
gh secret set AUR_USERNAME
gh secret set AUR_EMAIL
gh secret set AUR_KNOWN_HOSTS < aur-known-hosts
gh variable set AUR_PUBLISH --body true
```

Replace `/path/to/aur-private-key` with your private-key path.
The workflow uses strict SSH host verification.
It passes author details through environment variables and does not store them in the recipe.

With no `AUR_PUBLISH=true` variable, the release still produces the tested AUR recipe as a downloadable archive.
The workflow publishes to AUR only after the GitHub release succeeds.

## Package contents

The Arch package includes:

- `flux`, `fluxd`, and `flux-gui` in `/usr/bin`.
- The static `flux-approve` helper in `/usr/lib/flux`.
- Plugin files and shared views in `/usr/share/flux/omarchy-plugin`.
- The systemd user service and webcam udev rule.
- Desktop entry, icons, and install scripts.

The package build uses `DESTDIR` and does not run live system setup.
Pacman runs the install hook after installation.
Users then run `flux setup` to start the daemon and refresh their plugin copy.

CI builds the binary package on `x86_64`.
The source recipe also supports native `aarch64` builds, which require separate verification.

## Prepare the AUR source locally

Set `REPO` to the actual GitHub owner and repository:

```sh
REPO=OWNER/omarchy-flux
python3 scripts/prepare-aur.py --tag v0.1.0 --repo "$REPO"
cd dist/aur
makepkg --printsrcinfo > .SRCINFO
makepkg
```

The script downloads the tag archive and hashes its exact bytes.
It reads the recipe and hook from that archive, then sets its URL, version, checksum, and extracted directory.
The resulting recipe builds outside the Flux checkout.

`--archive PATH` accepts a downloaded GitHub archive for offline verification.
A locally generated tar archive has different bytes and must not supply a checksum for the public GitHub URL.

## Publish a version

After the local checks pass, create and push a stable tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow checks out the exact tag for both builds.
It waits for desktop and Android checks before publication.
The release starts as a draft until all assets upload.

Artifacts include:

- `omarchy-flux-VERSION-1-x86_64.pkg.tar.zst`.
- An Arch debug-symbol package when makepkg enables it.
- `flux-android-VERSION.apk`.
- `omarchy-flux-VERSION-aur.tar.gz` with `PKGBUILD`, `.SRCINFO`, and the install hook.
- `android-certificate.txt`.
- `SHA256SUMS`.

For a manual rebuild of an existing tag:

```sh
gh workflow run release.yml -f tag=v0.1.0
```

A manual run selects the existing tag's source rather than the dispatch branch's source.
It replaces assets with the same names and preserves the release notes.
The AUR job refuses to replace a newer package version with an older release.

## Check the result

```sh
gh run list --workflow release.yml
gh release view v0.1.0
```

Download the assets and verify `SHA256SUMS` before a test install.
Compare the Android certificate with the previous release.
Test a clean desktop install and an Android update with the same signing key.

If the AUR job fails after publication, fix its credentials or host entry and rerun that failed job.
The GitHub release remains available.
