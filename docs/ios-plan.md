# iOS client plan

[Documentation index](README.md)

This plan builds Flux for iOS: a native Swift and SwiftUI app for iPhone that takes the place of the Android phone app toward `fluxd`.
It shares FluxKit with [Flux for macOS](macos.md) and offers the Android features that iOS allows.

## Decisions

- [ ] The iPhone is a device peer that replaces the Android app, like the Mac.
- [ ] Native Swift and SwiftUI, iOS 17 or later. Citadel needs iOS 17, and so does `AVSampleBufferVideoRenderer`.
- [ ] FluxKit in `macos/Package.swift` builds for iOS and macOS. The package stays where it is, so the Mac app does not change.
- [ ] Platform code in FluxKit uses `#if os(macOS)` and `#if os(iOS)` inside the file that needs it. Public APIs that both apps use keep their names.
- [ ] XcodeGen project in `ios/project.yml`. The app sources are in `ios/App`. The generated project stays out of Git.
- [ ] One `FluxPlugin` per feature, composed in `ios/App/Features/Features.swift` with one line per entry, like the Mac app.
- [ ] The iPhone announces itself as `phone` and only the capabilities that it implements.
- [ ] Discovery follows Android and the Mac: the iPhone listens on TCP 1716 to 1764 and publishes `_kdeconnect._udp` through Bonjour, and `fluxd` connects to it. The iPhone also sends its identity by unicast UDP to each computer that it resolves through Bonjour. It sends no UDP broadcasts, because they need the multicast entitlement.
- [ ] Wire formats follow the Android app and the Go handlers exactly. New FluxKit wire code gets unit tests.
- [ ] No signing settings are committed. The simulator needs none. A device build uses the developer's own team in Xcode.

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

- [ ] Send files from the Files picker and photos from the photo picker, send text and links.
- [ ] Receive files, text, and links. Open received files with Quick Look.
- [ ] Clipboard text both ways, and clipboard images with `flux.clipboard.image`.
- [ ] Send new screenshots and photos when Flux opens.
- [ ] Media control of the computer's players.
- [ ] Desktop commands.
- [ ] Battery both ways, ring the phone with `findmyphone.request`, and Focus reports through a Focus filter.
- [ ] Checked against `fluxd`: files both ways with identical sha256, text, links, clipboard, media, commands, battery, and ring.

## Phase 4: Touchpad, keyboard, and remote desktop

- [ ] Touchpad with Android's gestures: move with acceleration, taps by finger count, two-finger scroll, hold to drag.
- [ ] Key panel: esc, tab, arrows, one-shot ctrl, alt, shift, and super, backspace, enter, and a type field.
- [ ] Hardware keyboard keys on the touchpad and the remote desktop.
- [ ] Remote desktop: pinned TLS listener, H.264 frames in `AVSampleBufferDisplayLayer`, fit, pinch zoom, and pan.
- [ ] Remote desktop touches as on Android: tap, double tap, hold for right click, hold and move to drag, two-finger tap and scroll.
- [ ] Monitor picker, the Omarchy panel with `flux.shortcuts`, and dictation typed as text.
- [ ] Checked: the remote desktop of an Omarchy computer shows and follows touches from the simulator.

## Phase 5: herdr agents and browse

- [ ] FluxKit: the full `flux.herdr` state with terminals, panes, workspaces, and kinds.
- [ ] FluxKit: `create`, `close`, and `input` packets, the `created` and `closed` answers, and Android's timeouts.
- [ ] FluxKit: the terminal keys with ctrl+a to ctrl+z, and reads of 1000 lines.
- [ ] Agents screen: blocked agents first, status, terminals, and the add button.
- [ ] New agent: run choice, folder search and picker, new tab or new workspace, and an optional first task.
  The first task goes as a `prompt` when the new agent is idle.
- [ ] Agent screen: colored output, numbered choices, key bar, reply field, dictation, and Close.
- [ ] Terminal screen: output every 3 seconds, key bar with ^C and ^D, Run, and Close.
- [ ] Agent notifications for needs input and finished, with a tap that opens the agent.
- [ ] Browse the computer's shared folders read-only through SFTP in a `flux.tunnel`, and save downloads to Files.
- [ ] Checked against `fluxd` with herdr: start an agent with a task, answer it, close it, and run a command in a terminal.

## Phase 6: Camera, webcam, and microphone

- [ ] Camera modes: Text, QR, Photo, Document, and Signature, from the camera or a picked image.
- [ ] Webcam in H.264 with the front and back cameras.
- [ ] Microphone as a 48 kHz mono stream, with the webcam option to also send the microphone.
- [ ] Checked: every mode's output at `fluxd` from picked images in the simulator.
- [ ] Checked on a device: camera capture, webcam, and microphone.

## Phase 7: Fingerprint approval

- [ ] Secure Enclave key that needs Face ID or Touch ID for every signature.
- [ ] Approval prompt in the app and as a notification while Flux runs.
- [ ] Checked: enrollment and an approval that the Go verifier accepts.

## Phase 8: Share extension

- [ ] A share extension for files, images, text, and links, with an App Group for the queue.
- [ ] The app sends queued items when it connects to the chosen computer.
- [ ] Checked: an item shared from Photos arrives at `fluxd` after Flux opens.

## Phase 9: Screen mirror

- [ ] A ReplayKit broadcast upload extension that encodes the screen in H.264 with the stream format of `flux.screen`.
- [ ] Build it when the stream runs inside the extension's memory limit. Else document that iOS does not mirror the screen.

## Phase 10: Documentation and integration

- [ ] [Flux for iOS](ios.md): build, install with Xcode, pairing, features, limits, permissions, and layout.
- [ ] Index, [architecture](architecture.md), and [development](development.md) updated.
- [ ] A CI job builds the iOS app and runs the FluxKit tests in the simulator.
- [ ] The Mac app builds with no new warnings, and `make test-macos` passes.
