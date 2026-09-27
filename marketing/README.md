# Marketing videos

This folder holds the source of the Flux feature videos and the steps to make them.
`video/` renders two videos: herdr agents on the phone, and Flux through Tailscale.
Use the same project for the next feature video.

Each video shows the Omarchy desktop on the left and Flux for Android on a phone on the right.
Headless Chromium renders each frame from HTML, and ffmpeg encodes the frames.
Every value in a frame is a pure function of the frame number, so a render gives the same result each time.

## Layout

| Path | Content |
| --- | --- |
| `video/STORYBOARD.md` | The scenes of each video: frames, phone screens, and every on-screen string |
| `video/KIT.md` | The scene contract and the API of the engine. Read it before you edit a scene. |
| `video/engine/` | The runtime, the animation helpers, and the UI parts: desktop, phone, split frame, captions, and heads-up |
| `video/scenes/` | The scenes. `h*` are the herdr video, `t*` are the Tailscale video. |
| `video/timeline-herdr.js`, `video/timeline-tailscale.js` | The scene order of each video |
| `video/audio/music.json` | The beat grid of the song and the cut points of each video |
| `video/tools/` | Scripts that fetch the fonts, capture the phone, and bake the phone screens |
| `video/render.mjs` | Renders a video, a scene, stills, or a contact sheet |
| `video/mux.sh` | Adds the music and writes the two deliverables |

Git keeps only the source.
The fonts, the wallpaper, the phone captures, the song, and the renders are local files that `video/.gitignore` lists.

## Requirements

- Node and npm.
- Chromium at `/usr/bin/chromium`.
- ffmpeg, ImageMagick 7 (`magick`), and jq.
- The `ttf-jetbrains-mono-nerd` package and the Omarchy Tokyo Night theme. Omarchy installs both.
- An Android emulator with a debug build of Flux for Android. See [Build and install](../docs/android.md#build-and-install).
- The song `Terminal Rain` as an MP3.

Use an emulator for the captures, not a personal phone.
A capture shows everything on the screen.

## Make the videos

1. Install the dependencies:

   ```sh
   cd marketing/video
   npm ci
   ```

2. Start the emulator. Turn on night mode, and set the device name to `Pixel 8` in the system settings.
3. Install the debug build on the emulator:

   ```sh
   (cd ../../android && ANDROID_SERIAL=emulator-5554 ./gradlew :app:installDebug)
   ```

4. From `marketing/video`, fetch the fonts and the wallpaper:

   ```sh
   ANDROID_SERIAL=emulator-5554 tools/fetch-assets.sh
   ```

5. Set `SONG` to your copy of the song, and copy it into the project:

   ```sh
   SONG="$HOME/Downloads/Terminal Rain.mp3"
   cp "$SONG" audio/music.mp3
   ```

6. Capture the phone screens:

   ```sh
   ANDROID_SERIAL=emulator-5554 tools/capture-phone.sh
   ```

7. Bake the patches into the phone screens:

   ```sh
   tools/bake-phone.sh
   ```

8. Render the herdr video and add the music:

   ```sh
   node render.mjs --timeline herdr --workers 2
   ./mux.sh herdr
   ```

9. Render the Tailscale video and add the music:

   ```sh
   node render.mjs --timeline tailscale --workers 2
   ./mux.sh tailscale
   ```

The deliverables are in `out/`:

| File | Use |
| --- | --- |
| `out/flux-herdr.mp4`, `out/flux-tailscale.mp4` | 1920 x 1080 at 60 fps |
| `out/flux-herdr-github.mp4`, `out/flux-tailscale-github.mp4` | 1280 x 720 for GitHub. `mux.sh` fails when a copy is 10 MB or more. |

`tools/capture-phone.sh` sets the SystemUI demo status bar to 9:41 with a full battery.
It turns demo mode off again when it ends.
`FLUX_DEMO=1` shows the sample computers and the sample herdr agents of the debug build.

A render takes a few minutes with 2 workers.
Use no more than 2 workers when another render runs.
With 4 workers each, Chromium failed with `Unable to capture screenshot`.

## Check a scene

Render stills or a contact sheet into `frames/`, then open the PNG files:

```sh
node render.mjs --timeline herdr --scene h04-read --stills 1307,1560,1700
node render.mjs --timeline tailscale --scene t03-leave --sheet 30
```

The sheet shows 1 frame every 30 frames.
Page errors print to the terminal, and the render fails when an image does not load.

## Make a new feature video

1. Pick one feature and one story. Show a problem, the Flux action, and the result.
2. Write the section of the video in `video/STORYBOARD.md`: the scenes, their frames, the phone screens, and every on-screen string.
3. Pick the part of the song. Put the most important moment on a hit, and cut the scenes on downbeats. See [Music timing](#music-timing).
4. Add the phone pages to `video/tools/capture-phone.sh`. The pages are in the [screenshot list](../docs/android.md#test). Run the capture again.
5. Add the patches to `video/tools/bake-phone.sh`. See [Phone patches](#phone-patches).
6. Write `video/timeline-<name>.js` and the scenes. Follow `video/KIT.md`. Check each scene with stills and sheets.
7. Add `videos.<name>` with `track_start_s` to `video/audio/music.json`. `mux.sh` reads it.
8. Render with `--timeline <name>`, then run `./mux.sh <name>`.

## Music timing

`Terminal Rain` runs at 71 BPM.
A beat is 0.845 s, about 50.7 frames, and a bar is 3.38 s, about 202.8 frames.
The downbeats are at 1.509 + 3.380282 m seconds of track time.
The song has 2 quiet breaks, at 24.0 to 27.7 s and 78.0 to 81.3 s.
Each break ends on a hard hit, at 28.55 s and 82.65 s.

| Video | Track start | Break in frames | Hit frame | Use of the hit |
| --- | --- | --- | --- | --- |
| herdr | 0 s | 1440 to 1662 | 1713 | The tap on the answer |
| Tailscale | 55.5935 s | 1344 to 1542 | 1623 | The link comes back through Tailscale |

To time another song, decode it and run the analysis in `video/audio`:

```sh
ffmpeg -i music.mp3 -ac 1 -ar 11025 -f f32le mono.f32
node analyze.mjs
node grid.mjs
```

`analyze.mjs` prints the loudness every 2 s and a first tempo.
`grid.mjs` fits the exact tempo and the phase of the first beat, and prints the loudness around the breaks.
Change the ranges in `grid.mjs` for another song.
`mux.sh` fades the music in over 0.4 s and out over the last 3 s.

## Phone patches

The captures come from demo data, so some values need a patch:

| Patch | Why | Where |
| --- | --- | --- |
| `ip TEXT` | The header shows a real LAN address, or `127.0.0.1` on the offline page | Droid Sans Mono at 31.5 px, x 153, baseline 207 |
| `mpv` | The sample player is a brand name | Droid Sans Mono at 26.5 px, the last 3 cells of the label |
| `5g` | The emulator shows no mobile signal icon | A `5G` label and signal bars left of the battery |
| `nobadge` | The opening shot needs the Agents tile without the blocked count | The left half of the symmetric icon, mirrored at x 933.5 |

The app uses the Android monospace font, Droid Sans Mono, for the header and the labels.
So a patch that draws with that font at the right size and position matches the capture.

The positions fit the app layout at the time of the capture.
After a layout change, measure them again:

1. Find the text box: `magick home.png -crop 500x60+140+170 +repage -fuzz 12% -trim -format '%wx%h%O' info:`.
2. Draw the original text at a few sizes and baselines, and compare each try with the capture: `magick compare -metric RMSE`.
3. Keep the size and the position with the lowest error.

## Content rules

- Show only behavior that exists. Take app strings from the captures and the source.
- Write on-screen text in ASD-STE100: short sentences, active voice, and no hype.
- Use the example names and addresses: `Pixel 8`, `omarchy-xps`, `pixel-8`, 192.168.1.20, 192.168.1.42, 100.101.102.10, and 100.101.102.103.
- Keep real names, handles, addresses, and brand names off the screen.
- Keep the terminal to the agent pane. The videos do not show the herdr interface.
