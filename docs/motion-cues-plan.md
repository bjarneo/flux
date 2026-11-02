# Motion cues plan

[Documentation index](README.md)

This plan adds motion cues to Flux: flat, themed dots at the edges of the Omarchy screen that move with the motion of a vehicle.
They help a passenger who reads on a laptop in a car, a bus, or a train.
The phone measures the motion and sends it to `fluxd`. `fluxd` turns it into cue targets, and the omarchy-shell plugin draws the dots.
The feature is experimental and not medical advice. It is for passengers only.

The idea comes from [omarchy-motion-cues](https://github.com/maxweis/omarchy-motion-cues) (NCSA license).
That project reads the phone through GyrOSC or phyphox, which need an inbound UDP port, a private IPv4 address, and an extra app on the phone.
Flux uses its paired link instead, so it needs no new firewall rule, works through Tailscale, and needs no other phone app.
Flux writes its own model. If code is copied from omarchy-motion-cues, keep its NCSA notice next to that code.

## Decisions

- [x] The phone is the only motion source. The laptop has no accelerometer that Flux reads. The Mac and Windows apps do not send motion.
- [x] Android first. iOS second, only while the app is open, because CoreMotion stops in the background.
- [x] One new packet type, `flux.motion`, carried on the existing TCP link. No new port and no UDP.
- [x] `fluxd` owns the feature: the setting, the access check, the staleness, the idle stop, and the motion model.
- [x] `fluxd` draws nothing. The omarchy-shell plugin draws the overlay in a wlr-layer-shell window.
- [x] The motion model is Go code in `internal/core`, with unit tests. QML only animates toward the targets that `fluxd` publishes.
- [x] Motion cues are off by default, with a setting like remote input. The setting allows the feature; a start runs it.
- [x] A run starts by hand (Flux window, CLI, or phone), or by itself when the phone detects a vehicle. Vehicle detection is best effort: a phone that cannot detect a vehicle still works with a start by hand.
- [x] Only omarchy-shell draws the cues. The Qt app gets no overlay, and Flux does not support motion cues on a desktop without omarchy-shell.
- [x] Flat design: solid dots, no glints, no 3D effect, colors from the active Omarchy theme.
- [x] One inertia convention on both axes: the dots move against the motion of the vehicle, as the content would if it had mass. A left turn moves them right, a start moves them down. omarchy-motion-cues follows the same convention; its signs differ only because screen y grows down. Check it in a real car before the release.

## Phase 1: Protocol

- [x] Add `TypeFluxMotion = "flux.motion"` to `internal/proto/identity.go`, with a doc comment like the other types.
- [x] Add it to `Incoming`, and add it to `Outgoing` for the start and stop messages.
- [x] Bodies:
  - Desktop to phone: `{"action":"start","rate":30}` and `{"action":"stop"}`.
  - Desktop to phone, after the link starts and after a setting changes: `{"action":"config","enabled":bool,"auto":bool}`. The phone watches for a vehicle only while both are true.
  - Phone to desktop: `{"action":"vehicle","in":bool}` when the phone detects that it enters or leaves a vehicle, and `{"action":"start"}` or `{"action":"stop"}` when its user starts or stops the cues on the phone.
  - Phone to desktop, 1 sample: `{"t":<ms monotonic>,"x":<m/s²>,"y":<m/s²>,"z":<m/s²>,"mount":"flat"|"upright"}`.
    Acceleration has gravity removed, in the device axes of Android (`TYPE_LINEAR_ACCELERATION`). iOS converts `userAcceleration` from g to m/s² and to the same axes.
  - Phone to desktop, state: `{"action":"state","running":bool,"error":"..."}`, for example when the sensor is missing.
- [x] A batched sample form, `{"samples":[...]}`, with at most 16 samples, for Android sensor batching.
- [x] Limits: drop non-finite values and values with an absolute value over 200 m/s². Drop a body over 4 KiB.
- [x] Do not bump `ProtocolVersion`. A device that does not list `flux.motion` as incoming or outgoing has no motion cues.
- [x] Fuzz test `FuzzMotionBody` in `internal/core/motionmodel_test.go` instead of `internal/proto`, because the body is decoded in `core`. Packet tests in `internal/core/motion_test.go`.
- [x] Describe the bodies in `docs/motion-cues.md`.

## Phase 2: fluxd

### Setting and access

- [x] `MotionCues bool` as `motion_cues` in `internal/config/config.go`, off by default.
- [x] A per-device rule key `motionCues` in `internal/config/rules.go`, next to `remoteInput`.
- [x] `settings.set` key `motionCues` in `internal/core/api.go`, and the value in the settings block of the state.
- [x] `MotionAuto bool` as `motion_auto`, on by default, and the `settings.set` key `motionAuto`.
- [x] `flux-cli motion on|off|start|stop|auto on|off|status`. `on` and `off` change the setting; `start` and `stop` run or end the cues now.
- [x] Only 1 device feeds the cues at a time: the first allowed, connected device that answers start. A second device gets stop.

### Feed

- [x] New file `internal/core/motion.go`. Handle `flux.motion` in `handlePacket` in `internal/core/handlers.go`.
- [x] Send start on a start by hand, on a phone start, or on `vehicle` with `in` true while `motion_auto` is on. Send stop on a stop by hand, a phone stop, `vehicle` with `in` false, the setting turning off, or the device losing access.
- [x] A stop by hand during a vehicle trip holds until the phone reports `in` false, so the cues do not come back at the next detection event of the same trip.
- [x] Send `config` after the link starts and after `motion_cues` or `motion_auto` changes.
- [x] Ignore samples from a device that is not the feeding device, or when the setting is off.
- [x] Keep only the newest sample. A sample with a timestamp older than the last one restarts the model.
- [x] Stale after 1 s without a sample: the targets go to rest, and the overlay fades out.
- [x] Idle stop after 5 minutes under the motion threshold: send stop and show a toast. Make the time a config value, `motion_idle`. A run that vehicle detection started stops on `in` false instead, and the idle stop is the fallback.
- [x] Toast on an automatic start, "Motion cues on: <device> is in a vehicle", so the user knows why the dots appeared.

### Model

Inputs are the newest sample and the mount. Outputs are the cue targets.

- [x] Axes: `flat` uses lateral = x and forward = y. `upright` uses lateral = x and forward = -z.
- [x] Dead zone: values under 0.045 m/s² count as 0.
- [x] Offset: `clamp(-a * 30 * sensitivity, -46, 46)` px on each axis, smoothed with tau 0.13 s.
- [x] Flow speed: `clamp(a * 75 * sensitivity, -180, 180)` px/s along the dominant axis, smoothed with tau 0.22 s, with a dead zone of 0.12 m/s². It is not integrated, so a long turn keeps the flow and a stop ends it.
- [x] Density: strength `min(6, |a| * sensitivity)` with attack tau 0.18 s and release tau 0.55 s. It maps to the number of extra dots, 0 to 20.
- [x] Clamp dt to 0.001 to 0.15 s.
- [x] `sensitivity` is 0.5, 1, or 1.6, saved as `motion_sensitivity`. `size` is small, medium, or large, saved as `motion_size`.
- [x] Table tests for the dead zone, the clamps, the smoothing, the decay at rest, a new session, and a timestamp that goes back.

### IPC

- [x] A new event `motion`, `{"active":bool,"offsetX","offsetY","flowX","flowY","density","device":"<id>"}`, at most 30 per second.
- [x] Like `state`, a slow client gets only the newest `motion` event. The event never takes a place in the 256 message queue, so it cannot close a connection.
- [x] Send `motion` only to subscribers that asked for it, `{"method":"subscribe","params":{"motion":true}}`, so the Flux window does not get 30 events each second.
- [x] Send 1 event with `active` false when the feed stops or goes stale.
- [x] Document the event in `docs/ipc.md`.

## Phase 3: Overlay in the omarchy-shell plugin

- [x] New `gui/omarchy/MotionCues.qml`, loaded from `Service.qml` only while the setting is on, so a user without motion cues pays nothing.
- [x] A `Backend` connection that subscribes to `motion`. Reuse `Backend.qml` if it can take the flag, or add a second small connection.
- [x] One `PanelWindow` per screen through `Variants` over `Quickshell.screens`, with `WlrLayershell` namespace `flux-motion-cues`, layer Overlay, keyboard focus None, exclusion mode Ignore, anchored on all 4 edges, a transparent color, and `mask: Region {}` so clicks pass through.
- [x] Visible only while `active` is true. Fade in and out over 300 ms.
- [x] Dots in the edge strips only: left, right, top, and bottom, about 8 % of the short screen side each, never over the center. The strips start 48 px in from the edge, the largest offset, so a moved dot stays on the screen and off the bar.
- [x] 12 base dots and 20 extra dots that appear with `density`. Seeded layout, so it is the same on each start.
- [x] Each dot moves by the offset, drifts with the flow, wraps at the strip end with a short fade, and scales between 0.85 and 1.15 on each wrap.
- [x] A `FrameAnimation` that runs only while the cues move or settle, so the overlay costs nothing at rest.
- [x] Respect the omarchy-shell scale of each screen. All sizes are logical pixels.
- [x] The Qt app (`gui/app`) gets no overlay. A desktop without omarchy-shell has no motion cues.

### Design

- [x] A dot is a flat circle of 1 color: no ring, no gradient, no glint, no shadow.
- [x] Sizes in logical px: small 10, medium 14, large 20.
- [x] Fill color: the candidate with the best WCAG contrast against `background`, of `accent`, `foreground`, and `bright_foreground`, in that order of preference. Take `accent` when its contrast is 3:1 or more, so the theme character stays. Otherwise take the candidate with the highest contrast.
- [x] No ring. The first build had a 1.5 px ring in `background`; it was dropped for a single flat color. The accent has 3:1 contrast or more on every installed Omarchy theme.
- [x] Fill opacity: 0.85 for base dots. Extra dots fade in with density.
- [x] Follow theme changes at once. `Service.qml` already watches `colors.toml` and `Commons.Color`.
- [x] Put the contrast function in a small JS file next to the overlay, with tests in `gui/qml/tools` style, and check it against a light theme, a dark theme, and a theme with a low-contrast accent.

## Phase 4: Android

- [x] New plugin `android/app/src/main/java/org/omarchy/flux/core/MotionCues.kt`, registered in `Plugins.kt`, enabled only when the computer lists `flux.motion`.
- [x] On start, register `Sensor.TYPE_LINEAR_ACCELERATION` at the asked rate, with `maxReportLatencyUs` of about 100 ms so the sensor hub batches.
  Fall back to `TYPE_ACCELEROMETER` with a low-pass gravity filter when the phone lacks the linear sensor. Report `error` when it has neither.
- [x] Run inside `FluxService`, which already is a `connectedDevice` foreground service, so samples keep coming with the screen off.
- [x] Send samples in batches of up to 16, at most every 50 ms. Drop samples when the link falls behind; never queue.
- [x] Stop on stop, on link loss, and when the service stops.
- [x] Mount choice in the motion cues tile: Flat (phone lying down) or Upright (phone in a holder). Saved per computer.
- [x] A **Motion cues** tile under each paired computer on the **Computers** screen: the state, Start and Stop, the mount, and **Automatic start**. The app has no per-computer Access card.
- [x] No permission for the sensor. Android 12 and later limit sensor rates without `HIGH_SAMPLING_RATE_SENSORS`, but 30 Hz is under that limit. A partial wake lock, already declared, keeps the samples coming with the screen off. Vehicle detection adds `ACTIVITY_RECOGNITION`.
- [x] Unit tests for the batching, the gravity filter, and the body format.

### Vehicle detection (best effort)

- [x] Use the Activity Recognition Transition API of Google Play services: `IN_VEHICLE` enter and exit, registered with a `PendingIntent` to a broadcast receiver, so it works while the app sleeps.
- [x] Register only while the computer sent `config` with `enabled` and `auto` true. Unregister when either turns false or the computer is unpaired.
- [x] Ask for the runtime permission `ACTIVITY_RECOGNITION` (Android 10 and later) only when the user turns on automatic start, with a short reason. A denied permission turns automatic start off on the phone and shows a hint.
- [x] Without Google Play services, or without the permission, skip detection silently and show "Start by hand" in the motion row. Do not add a fallback detector.
- [x] On `IN_VEHICLE` enter, send `vehicle` with `in` true to each connected computer that allows it. Do not queue it. A computer that connects during a trip gets `in` true in reply to its `config`.
- [x] Debounce: send `in` false only after the exit holds for 60 s, so a stop at a light does not end the cues.
- [x] Keep the Play services dependency out of a build flavor that cannot use it, if the project has one. There is no such flavor; detection sits behind a `VehicleDetector` interface, so one can supply a no-op detector later.

## Phase 5: iOS

- [ ] `CMMotionManager.startDeviceMotionUpdates` at 30 Hz, `userAcceleration` times 9.80665, converted to the Android axes.
- [ ] Only while the app is in the foreground. Stop on background, and send `state` with `running` false and the reason, so the desktop shows "Open Flux on the iPhone".
- [ ] No vehicle detection on iOS. `CMMotionActivityManager` reports `automotive`, but the app cannot react in the background, so the cues start by hand.
- [ ] Add the limits to `docs/ios.md`.

## Phase 6: Flux window and docs

- [x] A **Motion cues** row in the **Access** card of the device page: on or off for every device, the rule of the device, Start and Stop, and the state of the run. Automatic start, sensitivity, and size are in `flux-cli motion`.
- [ ] The state shows `motion` for the window. Done in the state and the Access card; the bar widget does not show it yet.
- [x] `flux-cli doctor`: report when the setting is on but the omarchy-shell plugin is not installed, because then nothing draws the cues.
- [x] `docs/motion-cues.md`: what it does, the disclaimer, setup, the mount, the settings, the iOS limit, and the battery use.
- [x] Rows in `docs/README.md`, `docs/features.md`, `docs/cli.md`, `docs/configuration.md`, and the table in `README.md`.
- [x] A line in `docs/security.md`: a paired device with motion cues allowed sends acceleration data only. It cannot control the computer.

## Checks

- [x] `go test ./...` and the checks in [development](development.md) for each changed part.
- [x] Android unit tests and a build.
- [ ] A test with a phone on a desk: shake left and right, and check that the dots move the right way and come to rest.
- [ ] A test with the phone locked for 10 minutes: the samples keep coming, and the idle stop works.
- [ ] A test in a car, with both mounts, and a test that automatic start and stop follow the trip on a phone with Play services.
- [ ] A test on a phone without the permission: the cues still start by hand.
- [ ] A test of the overlay over a light browser page, a dark terminal, and a video, in 3 themes. Done on Hyprland with a fake fluxd and the tokyo-night accent over light and dark windows; the color rule is checked on all 23 installed themes. Video and other themes on screen are open.
- [ ] Check that clicks and keyboard focus pass through the overlay, and that fullscreen windows still show it. The layer uses an empty input region and no keyboard focus; not yet checked by hand.
- [ ] Measure the battery use of the phone over 30 minutes.
