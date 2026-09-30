# Release Flux

[Documentation index](README.md)

Stable tags build the complete desktop package and a signed Android APK.
The release workflow publishes both with an AUR recipe, certificate details, SHA-256 checksums, and a signature of the checksums.
An optional final job pushes the tested recipe to AUR.

## Workflow map

| Workflow | Trigger | Result |
| --- | --- | --- |
| `build.yml` | Push to `master`, pull request, manual run, or reusable call | Arch package, Go tests, Android tests, lint, debug APK, unsigned release build, FluxKit tests, ad hoc signed macOS app, the iOS app with its simulator tests, an unsigned iOS Release build, and checks of its permission texts and privacy manifests. Pull requests skip the macOS and iOS jobs. |
| `release.yml` | Push a `v*` tag or manually select an existing tag | Validated stable tag on `master`, tested desktop package, APK built without secrets and signed in a separate job, ad hoc signed macOS app, unsigned iOS app, `SHA256SUMS` and its signature, and GitHub release |
| `aur.yml` | Reusable call after release publication | AUR commit with `PKGBUILD`, `.SRCINFO`, and the install hook |

The workflows live in [`.github/workflows/`](../.github/workflows/).
The AUR flow follows cliamp's source-package pattern.
The APK flow follows the persistent-key release pattern from kleeamp in `cliamp-mobile`.

## First release setup

1. Push this repository and the workflows to GitHub.
2. Use `master` as the default branch, or update the build workflow's branch filter.
3. Create the [release environment](#release-environment).
4. Configure the Android secrets below.
5. Make the [release signing key](#release-signing-key).
6. Configure AUR access if you want automatic publication.
7. Select the source license before public distribution.

The repository currently has no selected license.
The package retains `LicenseRef-unknown` until the owner makes that choice.
Add the selected license file and update the package metadata together.

The release workflow accepts only stable `vMAJOR.MINOR.PATCH` tags, such as `v0.1.0`.
Prerelease tags fail validation.
The workflow also refuses a tag whose commit is not on `master`.
The GitHub source archive must be public for AUR users to download it.

## Release environment

The jobs that use secrets run in the GitHub environment `release`:

- `apk-sign` in `release.yml` signs the APK.
- `sign` in `release.yml` signs `SHA256SUMS`.
- `publish` in `aur.yml` pushes the recipe to AUR.

Other jobs, pull requests, and branches do not get these secrets.
Create the environment once:

1. In **Settings > Environments**, create the environment `release`.
2. Under **Deployment branches and tags**, select **Selected branches and tags**.
3. Add the tag rule `v*` and the branch rule `master`. A manual rebuild runs from `master`.
4. Optional: add a required reviewer. Then each job in the environment waits for an approval.

Set each secret in the environment, not in the repository:

```sh
gh secret set KEYSTORE_PASSWORD --env release
```

The workflows also read repository secrets with the same names, so an earlier setup continues to work.
After you move a secret into the environment, remove the repository secret:

```sh
gh secret delete KEYSTORE_PASSWORD
```

Protect the release refs with rulesets in **Settings > Rules**:

- A branch ruleset for `master` that requires a pull request.
- A tag ruleset for `v*` that limits who can create, update, and delete release tags.

An account with administration access can change the environment and the rulesets.
Give agents and other automation a fine-grained token without administration access.

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

Set these secrets in the [release environment](#release-environment) through GitHub settings or `gh secret set --env release`:

| Secret | Value |
| --- | --- |
| `KEYSTORE_BASE64` | Base64-encoded keystore |
| `KEYSTORE_PASSWORD` | Keystore password |
| `KEY_ALIAS` | The key alias, such as `flux` |
| `KEY_PASSWORD` | Private-key password |

From the GitHub checkout:

```sh
base64 -w0 "$HOME/.local/share/flux-release/flux-release.jks" | gh secret set KEYSTORE_BASE64 --env release
gh secret set KEYSTORE_PASSWORD --env release
gh secret set KEY_ALIAS --env release
gh secret set KEY_PASSWORD --env release
```

The `apk` job builds `app-release-unsigned.apk` with Gradle and has no secrets.
The `apk-sign` job gets that APK and checks its SHA-256 checksum from the `apk` job.
Then it aligns the APK with `zipalign` and signs it with `apksigner` from the Android SDK of the runner.
This job runs no Gradle and no third-party action, so build plugins and dependencies never see the key.
The job restores the keystore in the runner's temporary directory and removes it at the end of the step.

The job compares the signing certificate with `CERT_SHA256` in `release.yml` and fails for another certificate.
The SHA-256 digest of the Flux release certificate is:

```text
a9af3fb3886f2c7cf4e2c9d93824aed23314d4e4fb36a364373064aa11700884
```

The release includes `android-certificate.txt` with the output of `apksigner verify --print-certs`.

A leaked key needs a key rotation.
APK Signature Scheme v3 supports rotation with a signing lineage, which `apksigner rotate` makes.
Plan and test a rotation on a phone before you need it, and change `CERT_SHA256` with it.

`FLUX_VERSION` sets Android `versionName` from the tag without `v`.
`FLUX_VERSION_CODE` comes from the tag: `(MAJOR * 1000000 + MINOR * 1000 + PATCH) * 100`.
For example, `v0.8.0` gets the code `800000`.
A rebuild of a tag gets the same code, so a rebuild of an earlier tag never gets a higher code than a later release.
The last 2 digits stay free for a rebuild counter.
The workflow refuses a MAJOR above 20, and a MINOR or PATCH above 999.
Earlier releases used the workflow run number, which is lower than each code from a tag.
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
export FLUX_VERSION_CODE=100000
cd android
./gradlew :app:assembleRelease --no-daemon --no-configuration-cache
```

Use the code of the version, as the release workflow does.
The output is `android/app/build/outputs/apk/release/app-release.apk` relative to the repository root.
Without signing variables, Gradle produces `app-release-unsigned.apk` instead.
Partial signing credentials stop the build.

## AUR setup

The package name is `omarchy-flux`.
The AUR account must own or co-maintain that package.
For a new package, its first valid push creates the AUR repository.

Set these secrets in the [release environment](#release-environment):

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
gh secret set AUR_SSH_PRIVATE_KEY --env release < /path/to/aur-private-key
gh secret set AUR_USERNAME --env release
gh secret set AUR_EMAIL --env release
gh secret set AUR_KNOWN_HOSTS --env release < aur-known-hosts
gh variable set AUR_PUBLISH --body true
```

Replace `/path/to/aur-private-key` with your private-key path.
The workflow uses strict SSH host verification.
It passes author details through environment variables and does not store them in the recipe.

With no `AUR_PUBLISH=true` variable, the release still produces the tested AUR recipe as a downloadable archive.
The workflow publishes to AUR only after the GitHub release succeeds, and only for the highest stable tag.

## Release signing key

The `sign` job signs `SHA256SUMS` with an Ed25519 key and publishes the signature as `SHA256SUMS.sig`.
`flux-cli update` and `fluxd` check the signature with `PublicKey` in [`internal/release/sign.go`](../internal/release/sign.go).
Then they check the download against `SHA256SUMS`.
While `PublicKey` is empty, they check only `SHA256SUMS` and log that they do not check the signature.
While `PublicKey` is empty and the `RELEASE_SIGNING_KEY` secret is not set, the `sign` job shows a warning, and the release has no `SHA256SUMS.sig`.
After you set `PublicKey`, the `sign` job fails when the secret is not set or when its public key is not `PublicKey`.

To set up the key, do these steps in this order:

1. Make the key pair outside the repository:

   ```sh
   mkdir -p "$HOME/.local/share/flux-release"
   go run ./scripts/signsums keygen "$HOME/.local/share/flux-release/release-signing.key"
   ```

   The command writes the private key to the file and prints the public key.

2. Set the private key as a secret of the release environment:

   ```sh
   gh secret set RELEASE_SIGNING_KEY --env release < "$HOME/.local/share/flux-release/release-signing.key"
   ```

3. Publish a release, and check its `SHA256SUMS.sig` with the public key from step 1:

   ```sh
   dir=$(mktemp -d)
   gh release download v0.1.0 -D "$dir" -p 'SHA256SUMS*'
   go run ./scripts/signsums verify "$dir/SHA256SUMS" PUBLIC_KEY
   ```

   Replace `v0.1.0` with the tag of the release, and `PUBLIC_KEY` with the public key from step 1.
4. Set `PublicKey` in `internal/release/sign.go` to the public key from step 1.
5. Release that change.

A `flux-cli` or `fluxd` with a public key refuses a release without a valid `SHA256SUMS.sig`.
So keep the secret after you set `PublicKey`, and keep a backup of the private key.
Without the key, the installed copies cannot update themselves, and users must install the next release by hand.

To check the signature of a downloaded release with `PublicKey`, run from the checkout:

```sh
go run ./scripts/signsums verify SHA256SUMS
```

To check with another public key, give the key as the last argument.

The private key is a GitHub secret.
So the signature shows that the release workflow of this repository made `SHA256SUMS`, and that nobody changed the file after the workflow.
It does not protect against a changed workflow.
The [release environment](#release-environment) and the rulesets protect the workflow.

## Package contents

The Arch package includes:

- `flux-cli`, `fluxd`, and `flux-gui` in `/usr/bin`.
- The `flux` link to `flux-cli` in `/usr/lib/flux/bin`, and `/etc/profile.d/flux-path.sh`, which adds that directory to the end of `PATH`.
- The static `flux-approve` helper in `/usr/lib/flux`.
- Plugin files and shared views in `/usr/share/flux/omarchy-plugin`.
- The systemd user service and webcam udev rule.
- Desktop entry, icons, and install scripts.

The package build uses `DESTDIR` and does not run live system setup.
Pacman runs the install hook after installation.
Users then run `flux-cli setup` to start the daemon and refresh their plugin copy.

CI builds the binary package on `x86_64`.
The source recipe also supports native `aarch64` builds, which require separate verification.

## Prepare the AUR source locally

```sh
REPO=bjarneo/flux
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

The release workflow checks out the exact tag for all builds.
It waits for the desktop, Android, and macOS checks before publication.
The release attaches the macOS app from the `macos` job. The app is signed ad hoc and not notarized.
The release skips the iOS tests. The `ipa` job builds the iOS app in Release without signing, for sideload tools.
The release starts as a draft until all assets upload.

Only the highest stable tag on `master` becomes the latest release on GitHub.
A tag that is not on `master` gets no release and does not count.
A patch tag on an earlier line, such as `v0.6.1` after `v0.7.0`, gets a release that is not the latest.
`flux-cli update` and `fluxd` read only the latest release, so they do not offer that patch.
The run shows a warning for a release that is not the latest.

The workflow writes the release notes in the cliamp format:

- **What's Changed** lists each commit since the previous stable tag, with its author and a link to the commit.
- **Checksums (SHA256)** repeats the content of `SHA256SUMS`.
- **Full Changelog** links to the comparison with the previous stable tag.

To make the notes useful, give each commit on `master` a clear subject.

Artifacts include:

- `omarchy-flux-VERSION-1-x86_64.pkg.tar.zst`.
- An Arch debug-symbol package when makepkg enables it.
- `flux-android-VERSION.apk`.
- `flux-macos-VERSION.zip` with the universal macOS app.
- `flux-ios-VERSION.ipa` with the unsigned iOS app.
- `omarchy-flux-VERSION-aur.tar.gz` with `PKGBUILD`, `.SRCINFO`, and the install hook.
- `android-certificate.txt`.
- `SHA256SUMS`.
- `SHA256SUMS.sig` when the [release signing key](#release-signing-key) is set.

Installed copies of Flux find their updates by these names.
`flux-cli update` checks `SHA256SUMS.sig`, then checks `omarchy-flux-VERSION-PKGREL-ARCH.pkg.tar.zst` against `SHA256SUMS`.
Then `sudo` copies the package into a new folder that only root can read, checks the copy again, and runs `pacman -U` on the copy.
`fluxd` sends `flux-android-VERSION.apk` to a phone after the same checks.
Keep the names, `SHA256SUMS`, and `SHA256SUMS.sig` when you change the release workflow.

For a manual rebuild of an existing tag, run the workflow from `master`:

```sh
gh workflow run release.yml --ref master -f tag=v0.1.0
```

A manual run builds the source of the tag with the workflow files of the branch that you select with `--ref`.
The signing programs also come from that branch.
The run makes the release a draft while it replaces the assets, so no update reads a mix of earlier and new files.
During that time, GitHub gives the previous release as the latest release.
The run writes the release notes again, so the checksums in the notes match the new assets.
The AUR job refuses to replace a newer package version with an older release.

## Pinned tools

The workflows use fixed versions, so an upstream change does not reach a release without a commit in this repository:

- Each action has a full commit SHA with its version in a comment.
  Dependabot opens a pull request each week for new versions. See [`.github/dependabot.yml`](../.github/dependabot.yml).
- The `arch` job uses the `archlinux:base-devel` image by digest.
  To update it, get the new digest and replace it in `build.yml`:

  ```sh
  docker pull archlinux:base-devel
  docker inspect --format '{{index .RepoDigests 0}}' archlinux:base-devel
  ```

- The macOS and iOS jobs install XcodeGen `XCODEGEN_VERSION` and check `XCODEGEN_SHA256` in `build.yml` and `release.yml`.
  To get the checksum of another version, such as 2.46.0:

  ```sh
  gh api repos/yonaskolb/XcodeGen/releases/tags/2.46.0 --jq '.assets[] | select(.name == "xcodegen.zip") | .digest' | sed 's/^sha256://'
  ```

- The Gradle wrapper checks the Gradle download with `distributionSha256Sum` in `android/gradle/wrapper/gradle-wrapper.properties`.
  When you change the Gradle version, set the checksum with the version:

  ```sh
  cd android
  ./gradlew wrapper --gradle-version 9.3.1 \
    --gradle-distribution-sha256-sum "$(curl -fsSL https://services.gradle.org/distributions/gradle-9.3.1-bin.zip.sha256)"
  ```

- The Xcode builds copy `macos/Package.resolved` into the generated project and pass `-onlyUsePackageVersionsFromResolvedFile`.
  So the apps get the Swift package versions that `swift test` tests.
  A pin that does not fit `macos/Package.swift` stops the build.
  After a change of `macos/Package.swift`, run `swift package resolve` in `macos/` and commit `Package.resolved`.

The Android build has no Gradle dependency verification file.
The signing job runs no Gradle, so the Gradle dependencies never see the release key.
A verification file must list the checksum of each artifact that the build, the lint, and the tests resolve, and each dependency update must change it.
Add it together with automated dependency updates for Gradle.

## Check the result

```sh
gh run list --workflow release.yml
gh release view v0.1.0
```

Download the assets, and check `SHA256SUMS.sig` and `SHA256SUMS` before a test install:

```sh
dir=$(mktemp -d)
gh release download v0.1.0 -D "$dir" -p 'SHA256SUMS*' -p '*.pkg.tar.zst' -p '*.apk'
go run ./scripts/signsums verify "$dir/SHA256SUMS"
(cd "$dir" && sha256sum --check --ignore-missing SHA256SUMS)
```

While `PublicKey` is empty, `verify` needs the public key as the last argument.
Without the [release signing key](#release-signing-key), the release has no `SHA256SUMS.sig`, so skip the `verify` command.

The `apk-sign` job compares the Android certificate with the release certificate.
Test a clean desktop install and an Android update with the same signing key.

### Check an upgrade

Test the upgrade from the previous release on a computer with a paired phone:

1. Install the previous release package, run `flux-cli setup`, and pair the phone.
2. Open the Flux window.
3. Run `flux-cli update`, and confirm the pacman prompt.
   A previous release without `flux-cli update` needs `sudo pacman -U` with the new package.
4. Run `flux-cli version`. Both lines must show the new version.
5. Run `flux-cli status`. The phone must show as connected again.
6. Check that the open window shows **Flux was updated**, and select **Restart**.
7. Select **Send to phone** in the window, and install the update from the notification on the phone.
8. Run `flux-cli status`. The phone must show as connected, with no update offer.

`fluxd` restarts about 10 seconds after the install.
The release check of an installed `fluxd` finds the new release within 1 day.
To see the offer at once, run `flux-cli update --check`.

If the AUR job fails after publication, fix its credentials or host entry and rerun that failed job.
The GitHub release remains available.

## TestFlight

The workflows do not sign the iOS app or upload it to App Store Connect.
Upload a build to TestFlight from a Mac with Xcode 26 and XcodeGen.
[Flux for iOS on the App Store](ios-app-store.md) has the store text, the review notes, and the open items.

### Apple setup

Do these steps once, with the Apple account that publishes Flux:

1. Join the paid Apple Developer Program. A free Apple ID cannot upload to App Store Connect.
2. In **Certificates, Identifiers & Profiles**, register the App Group `group.org.omarchy.flux`.
3. Register the bundle IDs `org.omarchy.flux.ios` and `org.omarchy.flux.ios.share` with the **App Groups** capability and that group.
4. In App Store Connect, create the app with the bundle ID `org.omarchy.flux.ios`.
5. Add the account in **Xcode > Settings > Accounts**.

If the team cannot register `group.org.omarchy.flux`, change `FLUX_APP_GROUP` in `ios/project.yml`.
See [Install on an iPhone](ios.md#install-on-an-iphone).

### Upload a build

1. In `ios/project.yml`, set `MARKETING_VERSION` to the release version in the `Flux` and `FluxShare` targets.
   App Store Connect needs the same version in the app and in the share extension.
2. Set `CURRENT_PROJECT_VERSION` in both targets to a build number above the build number of the previous upload.
3. Run the iOS checks:

   ```sh
   make ios test-ios ios-release
   ```

4. Generate the project and open it:

   ```sh
   cd ios
   xcodegen generate
   open Flux.xcodeproj
   ```

5. For the **Flux** and **FluxShare** targets, select the team in **Signing & Capabilities**.
   The generated project stays out of Git, so the team ID stays out of the repository.
6. Select **Any iOS Device (arm64)** as the run destination, then select **Product > Archive**.
7. In the Organizer, select the archive, then **Distribute App**, then **TestFlight & App Store**.
8. In App Store Connect, answer the export compliance questions of the build.
9. In **TestFlight**, add internal testers.
   Test the pairing and the main features against a computer that runs `fluxd`.

A TestFlight build is not an App Store release.
Submit the build for review only after you complete the [open items](ios-app-store.md#open-items).

### Secrets for an upload job

The repository has no Apple secrets, and no workflow uploads the app.
An upload job needs an App Store Connect API key and the team ID in secrets of the [release environment](#release-environment), for example `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64`, and `APPLE_TEAM_ID`.
Do not commit signing certificates, provisioning profiles, API keys, or team IDs.
