# Flux video kit

The videos render at 1920x1080 and 60 fps. Headless Chromium renders each
frame of HTML, and ffmpeg encodes the frames. Every value in a frame is a
pure function of the frame number.

Each video has a timeline, `timeline-<name>.js`, that lists its scenes in
order. `--timeline <name>` selects it. The default is `herdr`. See
`../README.md` for the full process and `STORYBOARD.md` for the scenes.

## Scene contract

A scene is one file, `scenes/<id>.js`:

```js
import { h, css, place, box } from '../engine/dom.js'
import { sec, interp, progress, spring, inOut, typed, ease, clamp, lerp, blink, rand } from '../engine/anim.js'
import { C, FONT, DESK, PHONE, hyprQuint, bezier } from '../engine/tokens.js'

export default {
  id: 'sudo',
  duration: sec(9),          // frames
  mount(layer, props) {      // build the DOM once, return refs
    ...
    return { ... }
  },
  update(r, f, ctx) {        // f is the local frame, 0 .. duration - 1
    ...
  },
}
```

Rules:

- Build all DOM and every `<img>` in `mount`. The runtime waits for images
  and fonts before frame 0. Do not create images in `update`.
- Do not read the clock, use `Math.random()`, CSS transitions, CSS
  animations, `setTimeout`, or `requestAnimationFrame`. Use `rand(seed)`.
- `update` must give the same result for a frame in any order. Set every
  animated property on every frame, also outside its active range.
- Write only your own files: `scenes/<id>.js` and optional helpers in
  `scenes/<id>/`. Do not edit `engine/`, the timelines, or other scenes.
  If the kit needs a fix, copy the helper into your folder and note it.
- Image paths are relative to the project root, for example
  `assets/phone/home.png`.

## Render and check your scene

```sh
node render.mjs --timeline herdr --scene h02-ping --sheet 30      # contact sheet, 1 frame per 30
node render.mjs --timeline herdr --scene h02-ping --stills 0,120,300
node render.mjs --file scenes/h02-ping.js --sheet 30             # a scene file that no timeline lists
node render.mjs --timeline herdr --workers 2                      # out/herdr-master-silent.mp4
```

Output goes to `frames/`. Read the PNGs to check them. Page errors print to
the terminal. The render fails if an image does not load.

## Helpers

`engine/anim.js`: `sec(s)` to frames. `interp(f, [f0, f1, ...], [v0, v1, ...], easing)`
holds at the ends. `progress(f, a, b, easing)` gives 0 to 1. `spring(f, start, {stiffness, damping})`.
`inOut(f, a, b, n)` fades in at a and out before b. `typed(text, f, start, cps)`.
`blink(f)`. `ease.linear, inCubic, outCubic, inOutCubic, outQuint, inOutQuint, outExpo, inOutExpo, outBack, camera`.

`engine/dom.js`: `h(tag, props, ...children)`, `css(el, styles)`,
`place(el, { x, y, s, sx, sy, r, o, blur })` sets transform and opacity,
`box(x, y, w, h, props, ...children)`.

`engine/tokens.js`: colors `C` (Tokyo Night: `bg #1a1b26`, `bg2 #13141c`, `bg3 #292e42`,
`fg #a9b1d6`, `fgBright #c0caf5`, `accent #7aa2f7`, `ok #9ece6a`, `err #f7768e`,
`warn #e0af68`, `cyan #449dab`, video text `ink`, `inkDim`), fonts `FONT.sans` (Inter),
`FONT.mono` (JetBrainsMono Nerd Font), `FONT.notif` (Liberation Sans), `DESK` (1440x900,
bar 26, gapOut 10, gapIn 6, border 2), `PHONE` (1080x2400), `hyprQuint` easing.

## Components

`engine/ui/bits.js`
- `stageBg()`: the dark stage, 1920x1080.
- `fluxMark(size, { fg, accent })` with `draw(p)`: the ring traces in, then the bar drops.
- `cursor()` with `at(x, y, framesSinceClick, opacity)`, and `path(points, f)`.
- `camera(world, [{ f, x, y, s }], f)`: puts world point x, y at the frame
  center with zoom s. Use it on a world container that holds the desktop and the phone.

`engine/ui/desktop.js`
- `desktop({ wallpaper, next, clock, focused, occupied, fluxOnline })`: a 1440x900
  Omarchy desktop with the omarchy-shell bar. Returns `el, windows, notifs,
  overlay, bar, setWipe(p)`. `setWipe(p)` reveals `next` with the real
  omarchy-shell parallelogram wipe, 420 ms InOutCubic (25 frames).
- `bar.tooltip(text, o)` shows the Flux tooltip, for example `Pixel 8 · connected`.
- `bar.mark.setOnline(bool)`. `bar.fluxCenterX` is the widget center in desk px.
- Wallpaper: `3-sunset-lake`. `tools/fetch-assets.sh` writes only this one. For another
  wallpaper, add it to that script.

`engine/ui/windows.js`
- `hyprWindow({ x, y, w, h, active })`: a window in desk px, 2 px border,
  square corners. Put content in `.content`.
- `popin(f, start)` gives `{ s, o }` for the Hyprland window-open animation.
  `popout(f, start)` for the close.
- `imageStack({ name: src }, w, h)` with `show({ name: opacity })` for UI states.
- `terminal({ w, h })` with `render(lines, cursor)`. A line is an array of
  segments `{ t, c, b, i }`. `prompt('repo')` gives the Starship prompt
  `omarchy-flux main ❯`, `prompt('home')` gives `~ ❯`.
- `notification({ summary, body, icon, img })`: an omarchy-shell card at the
  top right (x 1055, y 31, 380 wide). Stack cards 8 px apart. `layerIn(f, start)`
  gives its fade-in opacity, `layerOut(f, start)` the fade-out.
- `appIcon(codepoint, color)`: a 40 px app tile with a Nerd Font glyph.

`engine/ui/phone.js`
- `phone({ name: src })`: a phone whose screen is 1080x2400 px. Place it with
  `place(p.el, { x, y, s })`. At s = 0.35 it is 399x861 px. `p.show({ name: opacity })`
  switches screens. `p.overlay` is above the screens, in screen px, for your
  own layers: camera images, toasts, prompts. `p.tap(x, y, f, start)` shows a
  touch at screen px.

`engine/ui/text.js`
- `caption({ kicker, title, sub, x, y, width, size })` with `update(f, start, end)`.
  Words rise from a mask.
- `reveal(text, style, opts)`: the same effect for one text block.
- `chip(text, style)`: a mono command chip.

`engine/ui/feeds.js`
- `webcamFeed(w, h, { mirror })` with `update(f)`: a lit person silhouette in a room.
- `paperFeed(w, h, lines)` with `highlight(p)`: a paper page for the text scan.

`engine/ui/headsup.js`
- `headsUp({ app, sub, time, title, text })` with `update(f, start, end)`: the
  Android heads-up notification of Flux, in phone capture px. Append `el` to
  `phone.overlay`.

## Assets

Git keeps only `assets/misc/flux.svg`. The scripts in `tools/` write the rest.

- `assets/cap/*.png`: 1080x2400 emulator captures, dark mode, 9:41, from
  `tools/capture-phone.sh`.
- `assets/phone/*.png`: the captures with patches, from `tools/bake-phone.sh`.
  The table in `STORYBOARD.md` lists each screen.
- `assets/fonts/`, `assets/wallpapers/3-sunset-lake.jpg`: from
  `tools/fetch-assets.sh`.
- `assets/misc/flux.svg`: the icon for Flux notification cards.

## Text rules

On-screen text follows ASD-STE100: short sentences, active voice, simple
present tense. No em dashes, no semicolons, no parentheses, no exclamation
marks, no hype words. UI strings must match the app and the source exactly.

## The split frame

`engine/ui/split.js` implements the split frame. Every scene except the end
cards uses it. Do not rebuild the pane, the phone position, or the caption block.

```js
import { split, captions, arc, rings, SHOT, PANE, PHONE_AT, SCREEN_AT } from '../engine/ui/split.js'

mount(layer) {
  const s = split(layer, {
    wallpaper: '3-sunset-lake',
    bar: { focused: 1, occupied: [1, 2] },
    screens: { home: 'assets/phone/home.png', agents: 'assets/phone/agents.png' },
  })
  // s.desk.windows, s.desk.notifs, s.desk.overlay: desk px layers
  // s.phone.overlay: phone capture px layer above the screens
  // s.overlay: frame px layer above everything
  const c = captions(layer, { kicker: 'Security', title: '...', sub: '...', dir: 'Desktop → Phone' })
  const a = arc(s.overlay)
  return { s, c, a }
}
update(r, f) {
  r.s.camKeys([{ f: 0, shot: 'WIDE' }, { f: 50, shot: 'PANEL' }], f)   // or r.s.cam(z, cx, cy) or r.s.shot('RT')
  r.s.phone.show({ home: 1 })
  r.c.update(f, 18, duration)            // start at the caption beat, end at the scene end
  r.a.draw(f, 120, r.s.phoneToFrame(283, 1101), r.s.deskToFrame(1245, 60))
}
```

- `s.cam(z, cx, cy)`, `s.shot(name)`, `s.camKeys(keys, f)`: the pane camera.
  Shots: WIDE, HERO, HERO+, RT, MPV, BAR, PANEL, PANEL_WIDE, MIC, PAIR, CARD_TIGHT.
  The camera clamps so that no desktop edge shows.
- `s.deskToFrame(x, y)` and `s.phoneToFrame(u, v)` convert points to frame px,
  for arcs and frame-space effects. Call deskToFrame after the camera is set.
- `s.vibrate(f, start, frames)` shakes the phone.
- `captions(layer, { kicker, title, sub, dir })` with `update(f, start, end, subStart)`.
- `arc(layer).draw(f, start, a, b)`: the flux arc from a to b in frame px.
- `rings(layer).draw(f, start, end, x, y)`: accent rings at a frame point.
- `IP_PATCH` is for the old captures. The baked screens in `assets/phone/` need no IP patch.
- Screens can take patches: `{ src, patches: [{ x, y, w, h, fill, text, left, baseline, size, color }] }`
  in capture px. They show and hide with their screen.
- Android UI fonts for HTML parts on the phone: `'Roboto'` (variable),
  `'Roboto Static'` (400), `'Droid Sans Mono'`. Colors: page #121318,
  card #282a2f, primary #b2c5ff, text #e3e2e9, secondary #c4c6d0,
  snackbar #faf8ff with text #1b1b21.
- `assets/misc/flux.svg` is the icon for Flux shell notification cards.
