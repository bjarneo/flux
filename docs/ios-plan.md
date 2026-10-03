# iOS client plan

[Documentation index](README.md)

This plan builds Flux for iOS: a native Swift and SwiftUI app for iPhone that takes the place of the Android phone app toward `fluxd`.
It shares FluxKit with [Flux for macOS](macos.md) and offers the Android features that iOS allows.

## Decisions

- [x] The iPhone is a device peer that replaces the Android app, like the Mac.
- [x] Native Swift and SwiftUI, iOS 17 or later. Citadel needs iOS 17, and so does `AVSampleBufferVideoRenderer`.
- [x] FluxKit in `macos/Package.swift` builds for iOS and macOS. The package stays where it is, so the Mac app does not change.
- [x] Platform code in FluxKit uses `#if os(macOS)` and `#if os(iOS)` inside the file that needs it. Public APIs that both apps use keep their names.
- [x] XcodeGen project in `ios/project.yml`. The app sources are in `ios/App`. The generated project stays out of Git.
- [x] One `FluxPlugin` per feature, composed in `ios/App/Features/Features.swift` with one line per entry, like the Mac app.
- [x] The iPhone announces itself as `phone` and only the capabilities that it implements.
- [x] Discovery follows Android and the Mac: the iPhone listens on TCP 12100 to 12108 and publishes `_flux._udp` through Bonjour, and `fluxd` connects to it. The iPhone also sends its identity by unicast UDP to each computer that it resolves through Bonjour. It sends no UDP broadcasts, because they need the multicast entitlement.
- [x] Wire formats follow the Android app and the Go handlers exactly. New FluxKit wire code gets unit tests.
- [x] No signing settings are committed. The simulator needs none. A device build uses the developer's own team in Xcode.

## Limits of iOS

- iOS suspends Flux about 30 seconds after it leaves the screen. The link drops, and Flux connects again when it opens.
  Approvals, notifications, agent alerts, and clipboard changes reach the iPhone only while Flux runs.
- iOS gives apps no access to the notifications of other apps, to text messages, or to calls.
  Flux for iOS does not advertise `notification.request`, `sms.*`, or `telephony`.
- iOS asks before each clipboard read from another app, so the clipboard syncs while Flux is on the screen.
- New screenshots and photos go to the computer when Flux opens, not in the background.
- The share extension runs apart from the app and cannot hold a link. It queues items, and the app sends them when it connects.
- Flux cannot set the iOS Focus. It reports the Focus through a Focus filter and does not follow the computer.

## Phase 1: FluxKit on iOS

- [x] `platforms: [.macOS(.v14), .iOS(.v17)]`.
- [x] Device name: editable in Settings, "iPhone" by default. Device type: `phone`.
- [x] Battery from `UIDevice`, with level and state notifications.
- [x] Clipboard from `UIPasteboard`, read only while the app is active.
- [x] Received files in the app's Documents folder, visible in the Files app.
- [x] Opening files and links through a closure that each app provides.
- [x] Screenshot and photo sends from the Photos library.
- [x] Remote input: packet builders without AppKit, a key table for `UIKey` HID codes.
- [x] Microphone and dictation through `AVAudioSession` and `AVAudioEngine`.
- [x] Hardware encoder settings and camera device types per platform.
- [x] Screen capture with ScreenCaptureKit stays macOS only.
- [x] Approval texts name Face ID, Touch ID, or the passcode from `LAContext.biometryType`.
- [x] No UDP broadcast on iOS. Unicast UDP identity to Bonjour-resolved computers.
- [x] `swift test` passes on macOS, and the FluxKit tests pass in the iOS simulator.

## Phase 2: App shell

- [x] `make ios` builds the app for the simulator, `make test-ios` runs the tests in the simulator.
- [x] Computer list with paired and available computers, pairing in both directions with the key, and unpair.
- [x] Device screen: header with state and battery, quick actions, and one tile per feature, like the Android home screen.
- [x] Settings: device name, appearance, and feature switches.
- [x] Face ID or passcode lock that stays valid for 5 minutes, before replies, new agents, terminals, the touchpad, and the remote desktop.
  The features that use it come in their phases.
- [x] Notifications for pairing requests and `flux-cli notify`. Received files notify with the share feature in Phase 3.
- [x] Checked: the simulator pairs with `fluxd` on an Omarchy computer, pings both ways, and reconnects after the app returns.

## Phase 3: Share, clipboard, media, commands, and system

- [x] Send files from the Files picker and photos from the photo picker, send text and links.
- [x] Receive files, text, and links. Open received files with Quick Look.
- [x] Clipboard text both ways, and clipboard images with `flux.clipboard.image`.
- [x] Send new screenshots and photos when Flux opens.
- [x] Media control of the computer's players.
- [x] Desktop commands.
- [x] Battery both ways, ring the phone with `findmyphone.request`, and Focus reports through a Focus filter.
- [x] Checked against `fluxd`: files both ways with identical sha256, text, links, clipboard, media, commands, battery, and ring.
  The simulator reports no battery, so it sends none. Unit tests check the battery mapping.

## Phase 4: Touchpad, keyboard, and remote desktop

- [x] Touchpad with Android's gestures: move with acceleration, taps by finger count, two-finger scroll, hold to drag.
- [x] Key panel: esc, tab, arrows, one-shot ctrl, alt, shift, and super, backspace, enter, and a type field.
- [x] Hardware keyboard keys on the touchpad and the remote desktop.
- [x] Remote desktop: pinned TLS listener, H.264 frames in `AVSampleBufferDisplayLayer`, fit, pinch zoom, and pan.
- [x] Remote desktop touches as on Android: tap, double tap, hold for right click, hold and move to drag, two-finger tap and scroll.
- [x] Monitor picker, the Omarchy panel with `flux.shortcuts`, and dictation typed as text.
- [x] Checked: the remote desktop of an Omarchy computer shows and follows touches from the simulator.
  Taps land at the tapped position, also zoomed and panned, and the monitor chip, the Omarchy panel, Stop, and Start Again work.
- The volume keys do not change slides on iOS. iOS gives apps no public way to take the volume keys.

## Phase 5: herdr agents and browse

- [x] FluxKit: the full `flux.herdr` state with terminals, panes, workspaces, and kinds.
- [x] FluxKit: `create`, `close`, and `input` packets, the `created` and `closed` answers, and Android's timeouts.
- [x] FluxKit: the terminal keys with ctrl+a to ctrl+z, and reads of 1000 lines.
- [x] Agents screen: blocked agents first, status, terminals, and the add button.
- [x] New agent: run choice, folder search and picker, new tab or new workspace, and an optional first task.
  The first task goes as a `prompt` when the new agent stays idle or done for 2 seconds with no dialog on screen.
  Claude Code shows its next dialog right after the trust dialog, and herdr reports it idle for a moment between the two.
- [x] Agent screen: colored output, numbered choices, key bar, reply field, dictation, and Close.
- [x] Terminal screen: output every 3 seconds, key bar with ^C and ^D, Run, and Close.
- [x] Agent notifications for needs input and finished, with a tap that opens the agent.
- [x] Browse the computer's shared folders read-only through SFTP in a `flux.tunnel`, and save downloads to Files.
- [x] Checked against `fluxd` with herdr: start an agent with a task, answer it, close it, and run a command in a terminal.
  Also checked: ^C in a terminal, numbered choices, a follow-up prompt, both agent notifications, the blocked badge, and a browse download with identical sha256, Quick Look, and the share sheet.
  The simulator does not take injected taps on notifications, so the tap that opens the agent is not checked there.

## Phase 6: Camera, webcam, and microphone

- [x] Camera modes: Text, QR, Photo, Document, and Signature, from the camera, a picked photo, or a pasted image.
  Webcam is the sixth mode of the Camera screen. Android shows the webcam on its own screen under Control.
- [x] Webcam in H.264 with the front and back cameras, offered as `back` and `front` like Android.
  The stream stops with a notice when Flux leaves the screen, because iOS gives the camera only to the app on the screen.
- [x] Microphone as a 48 kHz mono stream, with the webcam option to also send the microphone.
  It records with `AVAudioEngine`, picks the input by the route of the audio session, and keeps streaming in the background with the `audio` background mode.
- [x] Checked: every mode's output at `fluxd` from picked images in the simulator.
  Text saves a scan file, QR copies the link on the computer, Photo saves a JPEG, Document saves a 1-page PDF with the page flattened, and Signature puts a transparent PNG on the clipboard, drawn or from paper.
  The simulator has no camera, so the camera screens and the webcam show No camera.
- [ ] Checked in the simulator: the microphone stream at `fluxd`.
  The audio input of this simulator stops the app with an RPC timeout in `AURemoteIO`, also in a bare `AVAudioEngine` test, so the stream is not checked yet.
- [ ] Checked on a device: camera capture, webcam, and microphone.
  Device only: the simulator has no camera, and its audio input fails as above.

## Phase 7: Fingerprint approval

- [x] Secure Enclave key that needs Face ID or Touch ID for every signature.
  It uses the FluxKit key of the Mac: P-256 with `.privateKeyUsage` and `.biometryCurrentSet`, and no key outside the Secure Enclave.
  A device without a Secure Enclave refuses each request at once and says so. The simulator counts as one, because it refuses a key that needs the biometry.
- [x] Approval prompt in the app and as a notification while Flux runs.
  A sheet shows the request with a countdown, Approve with Face ID or Touch ID, and Deny, and a banner shows a hidden request again.
  The notification has Deny, which works on the lock screen, and Approve, which needs the iPhone unlocked and opens the sheet.
  It asks for the time-sensitive level, but the project does not set the time-sensitive entitlement, so iOS shows it as an active notification, which a Focus holds back. See `docs/ios.md`.
- [x] Checked in the simulator against `fluxd`, through its socket without root: a request without a key and an enrollment are refused with their reasons.
- [ ] Checked on a device: enrollment and an approval that the Go verifier accepts.
  The simulator cannot make the key, so this needs an iPhone with Face ID or Touch ID and `sudo flux-cli approve setup`.

## Phase 8: Share extension

- [x] A share extension for files, images, text, and links, with an App Group for the queue.
  The App Group id is the `FLUX_APP_GROUP` build setting in `ios/project.yml`, `group.org.omarchy.flux` by default.
  The simulator needs no team. A device build needs the developer's team and a group id that the team owns, set in that 1 place.
- [x] The app sends queued items when it connects to the chosen computer.
  It removes each item after the computer received it, keeps failed items with the reason, lists them on the Share screen with Remove, and posts a notification when queued items went out.
- [x] Checked: an item shared from Photos arrives at `fluxd` after Flux opens.
  A photo from Photos arrived with the sha256 of the queued copy, a link from Safari opened on the computer, and queued text landed on its clipboard, all after Flux opened.
  Safari's Share for selected text shows no share sheet in this simulator, so the text went into the queue as the extension writes it; unit tests cover how the extension reads text.

## Phase 9: Screen mirror

- [ ] A ReplayKit broadcast upload extension that encodes the screen in H.264 with the stream format of `flux.screen`.
  Not built: iOS does not mirror the screen to a computer. The iPhone does not announce `flux.screen`, and the app has no Screen Mirror tile.
- [x] Build it when the stream runs inside the extension's memory limit. Else document that iOS does not mirror the screen.
  The stream could not be shown to run inside the limit of about 50 MB, and the design needs a change to `fluxd`, so it is documented here instead.

Why iOS does not mirror the screen:

- The simulator cannot run a broadcast, so nothing here can check an extension.
  The iOS 26.3 simulator runtime has no `replayd`. `RPSystemBroadcastPickerView` logs the button press and shows no picker, and `RPScreenRecorder.startCapture` for the app's own screen reports that it started but delivers no frame.
- The memory limit could not be checked.
  A broadcast upload extension gets about 50 MB. In the simulator, the stream at the `flux.screen` size of 496 × 1080 took about 1 MB for `FluxTLS`, the TLS listener, and 1 connection, and about 120 MB with the VideoToolbox H.264 encoder running, because the simulator encodes in software inside the process.
  A device encodes in hardware outside the process, so the real figure needs an iPhone.
- The stream would end soon after it starts.
  The broadcast runs in the extension process, and the app goes to the background when the user leaves it to show another app. The app then closes its links when its background time ends, and `fluxd` ends a mirror when the link that started it drops (`cancelOnLinkDown` in `internal/core/screen.go`).
  Keeping the app awake with the `audio` background mode while no audio streams is not acceptable. A second link from the extension would give 2 processes with 1 device id and 1 certificate, which `fluxd` sees as the same device.
- A design that keeps it alive needs 3 changes that cannot be checked without a device:
  `fluxd` keeps an iPhone's mirror while the stream socket is open, also after the link drops, with a flag in the "start" packet so Android and the Mac keep their behavior;
  the app shares its private key and certificate with the extension through the App Group or a keychain access group, which puts the identity key in a second process;
  and the app sends "start" for the extension, which announces its port through the App Group while the app is still on the screen.

- [ ] Checked on a device: whether an extension with the encoder and the TLS listener stays under the memory limit, before the design above is built.
  Device only: the simulator runs no broadcast and encodes in software inside the process.

## Phase 10: Documentation and integration

- [x] [Flux for iOS](ios.md): build, install with Xcode, pairing, features, limits, permissions, and layout.
- [x] Index, [architecture](architecture.md), and [development](development.md) updated.
- [x] A CI job builds the iOS app and runs the FluxKit tests in the simulator.
  The `ios` job in `build.yml` runs `make ios test-ios` on `macos-26`. The `macos` job runs `make test-macos macos`.
- [x] The Mac app builds with no new warnings, and `make test-macos` passes.
  A clean build of the Mac app has the same 2 deprecation warnings in `LanBackend.swift` as upstream `master`, and the iOS build has no warning in `ios/`.
