# Motion cues

[Documentation index](README.md)

Motion cues show flat dots at the edges of the screen that move with the motion of a vehicle.
They can help a passenger who reads on the laptop in a car, a bus, or a train.
The phone measures the motion and sends it to `fluxd`, and the Flux plugin of omarchy-shell draws the dots.

Motion cues are experimental and not medical advice.
Use them as a passenger only. Stop when they make you feel worse.

## What you need

- Flux for Android with motion cues. Flux for iOS and Flux for macOS do not send motion yet.
- The Flux plugin of omarchy-shell. Only the plugin draws the dots. `flux-cli setup` adds it, and `flux-cli doctor` reports when it is missing.

## Turn on motion cues

Motion cues are off by default.
Select **Turn on** under **Motion cues** in the **Access** card on the **Phone** page of the Flux window, or run:

```sh
flux-cli motion on
```

The **Motion cues** switch in the card is the rule of that device.
A device with the switch off sends no motion.

## Start and stop

Motion cues start in 3 ways:

- By hand on the computer: **Start** under **Motion cues** in the **Access** card, or `flux-cli motion start`.
- By hand on the phone: **Start** in the **Motion cues** tile under the computer on the **Computers** screen.
- By themselves, when the phone detects that it is in a vehicle. See [automatic start](#automatic-start).

The dots show when the first motion arrives, and fade out when the phone sends no motion for 1 second.
To stop them, select **Stop** in the card or on the phone, or run `flux-cli motion stop`.

Motion cues stop by themselves:

- After 5 minutes without motion. `flux-cli motion idle SECONDS` changes the time, from 30 to 3600 seconds.
- When the phone leaves the vehicle, for a start that vehicle detection made.
- When the phone disconnects, or loses its access.

`flux-cli motion` shows the state and the settings.

## Automatic start

Flux for Android can start the cues when it detects that you are in a vehicle.
It uses the activity recognition of Google Play services.
Turn on **Automatic start** in the **Motion cues** tile of the phone. The phone then asks for the physical activity permission.
On a phone without Google Play services, or without the permission, the tile says **Start by hand**.

Automatic start needs both sides: **Automatic start** on the phone, off by default, and `motion_auto` on the computer, on by default.
To turn it off on the computer, run `flux-cli motion auto off`.
A computer that connects during a trip gets the vehicle state at once.

When you stop the cues during a trip, they stay off until the phone reports the end of the trip.
The phone reports the end after 1 minute out of the vehicle, so a stop at a traffic light does not end the cues.

## Phone position

Choose the position in the **Motion cues** tile of the phone. The phone saves it for each computer:

- **Flat**: the phone lies screen up, with its top to the front of the vehicle.
- **Upright**: the phone stands in a holder, with its screen to you and its top up.

## Look and settings

The dots are flat circles in the accent color of the active Omarchy theme.
When the accent has less than 3:1 contrast with the theme background, the dots use the foreground color with the most contrast instead.
The dots follow a theme change at once.

12 dots always show while the cues run. Up to 20 more dots show with stronger motion.
The dots stay in strips at the 4 edges of each screen and never cover the middle.
They take no clicks and no keyboard focus.

The dots move against the motion of the vehicle, as the content would if it had mass:

| Motion | Dots |
| --- | --- |
| Left turn | move right and drift right |
| Right turn | move left and drift left |
| Speed up | move down |
| Brake | move up |

| Command | Effect |
| --- | --- |
| `flux-cli motion sensitivity 0.5\|1\|1.6` | How far and how fast the dots move. Defaults to `1`. |
| `flux-cli motion size small\|medium\|large` | The dot size: 10, 14, or 20 pixels. Defaults to `medium`. |
| `flux-cli motion idle SECONDS` | The stop after a time without motion. Defaults to 300 seconds. |

The settings are `motion_cues`, `motion_auto`, `motion_sensitivity`, `motion_size`, and `motion_idle` in `config.toml`. See [configuration](configuration.md#settings).

## Battery

The phone reads its motion sensor about 30 times each second while the cues run, and sends the readings in groups.
It keeps the processor awake while the cues run, so that the readings go on with the screen off.
This uses battery. The idle stop ends a run that you forgot.

## Protocol

The packet type is `flux.motion`. Both sides list it as incoming and outgoing.
`fluxd` reads a body of at most 4 KiB.

From the computer to the phone:

| Body | Meaning |
| --- | --- |
| `{"action":"config","enabled":true,"auto":true}` | After the link starts and after a setting or a device rule changes. The phone watches for a vehicle only while both are `true`. |
| `{"action":"start","rate":30}` | Start the sensor at `rate` samples each second. |
| `{"action":"stop"}` | Stop the sensor. `fluxd` also sends it, at most every 2 seconds, to a phone that sends samples without a run. |

From the phone to the computer:

| Body | Meaning |
| --- | --- |
| `{"samples":[{"t":1234,"x":0.1,"y":-0.4,"z":0.0,"mount":"flat"}]}` | 1 to 16 samples. A body with `samples` counts as samples, also with an `action`. `t` is a monotonic time in milliseconds. `x`, `y`, and `z` are the acceleration without gravity in m/s², in the device axes of Android. `mount` is `flat` or `upright`. `fluxd` drops a sample with a value that is not finite or over 200 m/s², and the samples after the 16th. |
| `{"action":"state","running":false,"error":"no accelerometer"}` | The sensor state. A state with `running` false ends the run. |
| `{"action":"vehicle","in":true}` | The phone entered (`true`) or left (`false`) a vehicle. The phone sends `true` again after a `config` that turns detection on during a trip. It sends `false` after 1 minute out of the vehicle. |
| `{"action":"start"}`, `{"action":"stop"}` | The user started or stopped the cues on the phone. The phone starts its sensor only on the start of the computer. |

`fluxd` turns the samples into cue targets and sends them as `motion` events on the [IPC socket](ipc.md#motion-events).
