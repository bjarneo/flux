// The shared desk of the Tailscale video, t01 to t06. Every value is a
// function of the global video frame g, so the terminal, the phone, the
// bar, the camera, and the link lines continue across the cuts.
//
// A scene calls buildDesk(layer) in mount and deskAt(r, g) in update, with
// g = scene start + local frame.

import { h, css, place } from '../../engine/dom.js'
import { C, FONT } from '../../engine/tokens.js'
import { clamp, ease, lerp, typed, blink } from '../../engine/anim.js'
import { split, arc, rings, PANE, PHONE_AT } from '../../engine/ui/split.js'
import { hyprWindow, terminal, prompt, popin } from '../../engine/ui/windows.js'
import { cursor, path } from '../../engine/ui/bits.js'
import { headsUp } from '../../engine/ui/headsup.js'

/** Scene starts in global frames. */
export const T = { t01: 0, t02: 406, t03: 1014, t04: 1623, t05: 2231, t06: 2637, end: 3042 }

/** Beats in global frames. See STORYBOARD.md, Video 2. */
export const G = {
  wifiIn: 40,
  ptrIn: 20, ptrAt: 60, tipIn: 70, tipOut: 330, ptrAway: 372,
  win: 406,
  brk: 1344, down: 1380, hit: 1623,
  ptrBack: 1290, ptrBackAt: 1336,
  ctrlC: 1790,
  notify: 1900, heads: 1915, headsOut: 2150, arcN: 1905,
}

// The terminal: Ghostty at 16 px, so the lines read in the pane.
const FONT_PX = 16
const LINE = 22
const PAD = 19
const WIN = { x: 10, y: 36, w: 1420, h: 854 }
/** The desk y of the top of terminal row i. */
export const rowY = (i) => WIN.y + 2 + PAD + LINE * i
const CELL = FONT_PX * 0.6

const txt = (t, c) => ({ t, c })
const TS1 = [txt('100.101.102.10   omarchy-xps  you@  linux    -')]
const TS2 = [txt('100.101.102.103  pixel-8      you@  android  -')]
const ADD = [txt('flux --device "Pixel 8" addresses add ', C.fgBright), txt('pixel-8', C.accent)]
const ADDED = [txt('Added pixel-8. Addresses of Pixel 8: pixel-8')]
const ok = (t) => [txt('✓ ', C.ok), txt(t)]
const DOCTOR = [
  ok('fluxd is running'),
  ok('fluxd listens on TCP 1716'),
  ok('no other program uses UDP port 1716'),
  ok('ufw lets mDNS in, so fluxd finds phones with no open port'),
  ok('avahi-daemon runs, so fluxd can find phones with mDNS'),
  [txt('✓ ', C.ok), txt('pixel-8', C.accent), txt(' resolves, so fluxd can reach Pixel 8 through it', C.fgBright)],
]
// journalctl prints only new messages with -n 0, and only the text with -o cat.
const JOURNAL = [txt('journalctl --user -u fluxd -f -n 0 -o cat', C.fgBright)]
const DOWN = [txt('link down: Pixel 8: read tcp 192.168.1.20:45098->192.168.1.42:1716: read: connection timed out')]
const UP = [txt('link up: Pixel 8 (100.101.102.103) paired=true')]
const NOTIFY = [txt('flux notify "Build done" "412 files, 2.1 GB"', C.fgBright)]
const STATUS = [txt('flux status', C.fgBright)]
// flux status: '  %-22s %-7s %-10s %-6s %-15s %s'. The phone battery is 100 percent.
const ST1 = [txt('omarchy-xps (laptop) · TCP 1716')]
const ST2 = [txt('  Pixel 8                phone   connected  100%   100.101.102.103 paired')]

/**
 * The commands in order: typing start, characters per second, the Enter
 * frame, output lines [frame, segments], and the frame of the next prompt.
 */
const STEPS = [
  { cmd: [txt('tailscale status', C.fgBright)], start: 426, cps: 22, enter: 478, out: [[484, TS1], [488, TS2]], next: 494 },
  { cmd: ADD, start: 520, cps: 28, enter: 628, out: [[636, ADDED]], next: 644 },
  { cmd: [txt('flux doctor', C.fgBright)], start: 815, cps: 22, enter: 852, out: DOCTOR.map((l, i) => [858 + 4 * i, l]), next: 888 },
  { cmd: JOURNAL, start: 1040, cps: 28, enter: 1128, out: [[G.down, DOWN], [G.hit, UP], [G.ctrlC, [txt('^C')]]], next: 1800 },
  { cmd: NOTIFY, start: 1808, cps: 30, enter: G.notify, out: [], next: 1908 },
  { cmd: STATUS, start: 2250, cps: 22, enter: 2286, out: [[2292, ST1], [2296, ST2]], next: 2306 },
]

/** The rows of the notable lines, for the highlight bands and the arc. */
export const ROW = { resolve: 14, journal: 16, down: 17, up: 18, notify: 21, status: 25 }

const len = (segs) => segs.reduce((n, s) => n + [...s.t].length, 0)

/** The first n characters of a segment list. */
function cut(segs, n) {
  const out = []
  for (const s of segs) {
    if (n <= 0) break
    const chars = [...s.t]
    out.push({ ...s, t: chars.slice(0, n).join('') })
    n -= chars.length
  }
  return out
}

/** The terminal rows and the cursor at global frame g. */
export function termAt(g) {
  const lines = [[], prompt('home')]
  const idle = { on: blink(g) }
  for (const st of STEPS) {
    const row = lines.length - 1
    if (g < st.start) return { lines, cursor: { line: row, ...idle } }
    const n = Math.min(len(st.cmd), Math.floor(((g - st.start) / 60) * st.cps))
    lines[row] = [...prompt('home'), ...cut(st.cmd, n)]
    if (g < st.enter) return { lines, cursor: { line: row } }
    for (const [t, segs] of st.out) if (g >= t) lines.push(segs)
    if (g < st.next) {
      // The command runs. The cursor waits at the start of the next row.
      lines.push([])
      return { lines, cursor: { line: lines.length - 1, col: 0 } }
    }
    lines.push([], prompt('home'))
  }
  return { lines, cursor: { line: lines.length - 1, ...idle } }
}

/** The camera keys in global frames. */
const T2 = { z: 1.3, cx: 554, cy: 346 }
const T4 = { z: 1.15, cx: 626, cy: 420 }
const T5 = { z: 1.3, cx: 554, cy: 470 }
const CAM = [
  { f: 0, shot: 'WIDE' }, { f: 34, shot: 'WIDE' },
  { f: 100, z: 2.4, cx: 1130, cy: 160 }, { f: 330, z: 2.4, cx: 1130, cy: 160 },
  { f: 396, shot: 'WIDE' }, { f: 436, shot: 'WIDE' },
  { f: 500, ...T2 }, { f: 1250, ...T2 },
  { f: 1330, shot: 'WIDE' }, { f: 1780, shot: 'WIDE' },
  { f: 1850, ...T4 }, { f: 2236, ...T4 },
  { f: 2300, ...T5 },
]

/** The pointer in desk px at global frame g, with opacity. */
const W = { x: 1308, y: 13 }
const REST = { x: 1180, y: 262 }
function pointerAt(g) {
  if (g < G.ptrIn) return { x: 760, y: 520, o: 0 }
  if (g < G.ptrAway + 10) {
    const p = path([{ f: G.ptrIn, x: 760, y: 520 }, { f: G.ptrAt, ...W }, { f: G.tipOut, ...W }, { f: G.ptrAway, ...REST }], g)
    return { ...p, o: clamp((g - G.ptrIn) / 8) }
  }
  // Omarchy hides the pointer at the first key of 'tailscale status'.
  if (g < G.ptrBack) return { ...REST, o: g < 426 ? 1 : 0 }
  if (g < G.ctrlC) return { ...path([{ f: G.ptrBack, ...REST }, { f: G.ptrBackAt, ...W }], g), o: 1 }
  return { ...W, o: 0 }
}

/** The tooltip text and opacity at global frame g. */
function tipAt(g) {
  if (g >= G.tipIn && g < G.tipOut) return { t: 'Pixel 8 · connected', o: clamp((g - G.tipIn) / 8) * clamp((G.tipOut - g) / 6) }
  // The pointer is back on the widget. fluxd still has the old link until G.down.
  if (g >= G.ptrBackAt + 10 && g < G.down + 4) return { t: 'Pixel 8 · connected', o: clamp((g - G.ptrBackAt - 10) / 8) }
  if (g >= G.down + 4 && g < G.hit) return { t: 'Pixel 8 · offline', o: 1 }
  if (g >= G.hit && g < G.ctrlC) return { t: 'Pixel 8 · connected', o: clamp((G.ctrlC - g) / 6) }
  return { t: 'Pixel 8 · connected', o: 0 }
}

/**
 * A link line in the gap between the pane and the phone, in frame px:
 * the line, 2 end dots, and a label above it.
 */
const GAP = { x0: PANE.x + PANE.w + 8, x1: PHONE_AT.x - 6, y: 451 }
function linkLine(layer, label, color, dashed, glyph) {
  const svg = h('svg', { width: 1920, height: 1080, viewBox: '0 0 1920 1080', style: 'position:absolute;left:0;top:0;overflow:visible;pointer-events:none' })
  const defs = h('defs', {}, h('filter', { id: `g${label}`, x: '-50%', y: '-400%', width: '200%', height: '900%' }, h('feGaussianBlur', { stdDeviation: 3 })))
  const mk = () => h('line', { y1: GAP.y, y2: GAP.y, stroke: color, 'stroke-width': 2.5, 'stroke-linecap': 'round', ...(dashed ? { 'stroke-dasharray': '5 5' } : {}) })
  const glow = h('line', { y1: GAP.y, y2: GAP.y, stroke: color, 'stroke-width': 5, opacity: 0, filter: `url(#g${label})` })
  const left = mk()
  const right = mk()
  const dotA = h('circle', { cx: GAP.x0, cy: GAP.y, r: 3.5, fill: color })
  const dotB = h('circle', { cx: GAP.x1, cy: GAP.y, r: 3.5, fill: color })
  svg.append(defs, glow, left, right, dotA, dotB)
  // A Nerd Font icon over the label: wifi, or vpn for Tailscale.
  const lab = h('div', {
    style: {
      position: 'absolute', left: GAP.x0 - 20, width: GAP.x1 - GAP.x0 + 40, top: GAP.y - 64, textAlign: 'center',
      fontFamily: FONT.mono, fontSize: 16, lineHeight: '20px', color, whiteSpace: 'nowrap', visibility: 'hidden',
    },
  }, h('div', { style: { fontSize: 28, lineHeight: '32px', marginBottom: 4 }, text: String.fromCodePoint(glyph) }), h('div', { text: label }))
  layer.append(svg, lab)
  const mid = (GAP.x0 + GAP.x1) / 2
  return {
    /** draw p: how much of the line shows from the left. gap: px open at the middle. o: opacity. */
    set({ draw = 1, gap = 0, o = 1, color: col = color, glowO = 0 }) {
      const end = lerp(GAP.x0, GAP.x1, draw)
      const lEnd = Math.min(end, mid - gap / 2)
      left.setAttribute('x1', GAP.x0); left.setAttribute('x2', lEnd)
      right.setAttribute('x1', mid + gap / 2); right.setAttribute('x2', Math.max(mid + gap / 2, end))
      right.style.visibility = end > mid + gap / 2 ? 'visible' : 'hidden'
      glow.setAttribute('x1', GAP.x0); glow.setAttribute('x2', end); glow.setAttribute('opacity', glowO)
      for (const el of [left, right, dotA, dotB, glow]) { el.setAttribute('stroke', col); if (el.tagName === 'circle') el.setAttribute('fill', col) }
      dotB.style.visibility = draw >= 0.999 ? 'visible' : 'hidden'
      svg.style.opacity = String(o)
      svg.style.visibility = o > 0.001 && draw > 0 ? 'visible' : 'hidden'
      lab.style.color = col
      place(lab, { y: (1 - clamp(draw * 1.5)) * 6, o: o * clamp(draw * 1.5) })
    },
  }
}

/** A highlight band behind a terminal row, in desk px. */
function band(parent, row, color) {
  const el = h('div', {
    style: {
      position: 'absolute', left: 12, top: rowY(row) - WIN.y - 2, width: 0, height: LINE, background: color,
      borderLeft: '3px solid', borderColor: color.replace(/[\d.]+\)$/, '0.9)'), visibility: 'hidden',
    },
  })
  parent.prepend(el)
  return el
}

/**
 * Builds the split frame, the Ghostty window, the pointer, the link lines,
 * the Android heads-up, the phone status strip, and the effect layers.
 */
export function buildDesk(layer) {
  const s = split(layer, {
    wallpaper: '3-sunset-lake',
    bar: { focused: 1, occupied: [1] },
    screens: {
      wifi: 'assets/phone/ts-home-wifi.png',
      off: 'assets/phone/ts-offline-5g.png',
      ts: 'assets/phone/ts-home-5g.png',
      agents: 'assets/phone/ts-agents-5g.png',
    },
  })
  // A stable compositing layer for the rounded screen, as in the earlier video.
  css(s.phone.screen, { willChange: 'transform' })

  const win = hyprWindow({ ...WIN, active: true, opacity: 0.985 })
  const term = terminal({ w: WIN.w - 4, h: WIN.h - 4, font: FONT_PX, lineH: LINE, pad: PAD })
  win.content.append(term.el)
  s.desk.windows.append(win.el)
  // The bands sit behind the text: the terminal background is transparent above them.
  term.el.style.background = 'transparent'
  win.content.style.background = C.bg
  const bands = {
    resolve: band(win.content, ROW.resolve, 'rgba(122,162,247,0.16)'),
    down: band(win.content, ROW.down, 'rgba(247,118,142,0.16)'),
    up: band(win.content, ROW.up, 'rgba(158,206,106,0.18)'),
  }

  const ptr = cursor()
  s.desk.overlay.append(ptr.el)

  // The status bar of the phone without Wi-Fi, before the page changes.
  const strip = h('img', { src: 'assets/phone/ts-offline-5g.png', style: { position: 'absolute', left: 0, top: 0, width: 1080, height: 2400, clipPath: 'inset(0 0 2282px 0)', visibility: 'hidden' } })
  s.phone.overlay.append(strip)

  const hu = headsUp({ sub: 'omarchy-xps', title: 'Build done', text: '412 files, 2.1 GB' })
  s.phone.overlay.append(hu.el)

  // The dim of the break, over the pane and the phone.
  // It sits under s.overlay, whose z-index would also put it over the captions.
  const dim = h('div', { style: { position: 'absolute', inset: 0, background: '#05060a', visibility: 'hidden' } })
  s.root.insertBefore(dim, s.overlay)
  const wifi = linkLine(s.overlay, 'Wi-Fi', C.fgBright, true, 0xf05a9)
  const tail = linkLine(s.overlay, 'Tailscale', C.accent, false, 0xf0582)
  const a = arc(s.overlay)
  const rg = rings(s.overlay)

  // A fade from black at the start of the video.
  const black = h('div', { style: { position: 'absolute', inset: 0, background: '#000', zIndex: 40, visibility: 'hidden' } })
  s.root.append(black)

  return { s, win, term, bands, ptr, strip, hu, dim, wifi, tail, a, rg, black }
}

const show = (el, o) => { el.style.opacity = String(o); el.style.visibility = o > 0.001 ? 'visible' : 'hidden' }

/** Sets every shared part for global frame g. */
export function deskAt(r, g) {
  const { s } = r
  s.camKeys(CAM, g)

  // The window opens at the start of t02.
  const pi = popin(g, G.win)
  place(r.win.el, { s: pi.s, o: pi.o })
  const t = termAt(g)
  r.term.render(t.lines, t.cursor)

  // Highlight bands grow from the left when their line prints.
  const grow = (el, start, end = Infinity) => {
    const p = ease.outCubic(clamp((g - start) / 14))
    const out = clamp((g - end) / 14)
    el.style.width = `${Math.round(lerp(0, 1110, p))}px`
    show(el, g >= start ? 1 - out : 0)
  }
  grow(r.bands.resolve, 878, 1030)
  grow(r.bands.down, G.down, G.hit + 40)
  grow(r.bands.up, G.hit, T.t05 + 20)

  // The bar: Flux goes offline with the link, and online again on the hit.
  s.desk.bar.mark.setOnline(!(g >= G.down && g < G.hit))
  const tip = tipAt(g)
  s.desk.bar.tooltip(tip.t, tip.o)
  const p = pointerAt(g)
  r.ptr.at(p.x, p.y, -1, p.o)

  // The phone.
  const screen = g < G.down ? 'wifi' : g < G.hit ? 'off' : g < T.t05 ? 'ts' : 'agents'
  s.phone.show({ [screen]: 1 })
  r.strip.style.visibility = g >= G.brk && g < G.down ? 'visible' : 'hidden'
  r.hu.update(g, G.heads, G.headsOut)

  // The Wi-Fi line draws in, then breaks at the start of the break.
  const wDraw = ease.outCubic(clamp((g - G.wifiIn) / 24))
  const brk = clamp((g - G.brk) / 22)
  r.wifi.set({
    draw: wDraw,
    gap: ease.outCubic(brk) * 44,
    color: g >= G.brk ? C.err : C.fgBright,
    o: 1 - ease.inCubic(clamp((g - G.brk - 16) / 40)),
  })
  // The Tailscale line draws in on the hit and stays.
  const tDraw = ease.outCubic(clamp((g - G.hit) / 16))
  r.tail.set({ draw: g >= G.hit ? tDraw : 0, glowO: 0.9 * (1 - clamp((g - G.hit - 10) / 50)) + 0.25 })

  // The break dims the pane and the phone, and the hit lifts it at once.
  const d = g < G.hit ? 0.28 * ease.outCubic(clamp((g - G.brk) / 48)) : 0.28 * (1 - clamp((g - G.hit) / 8))
  show(r.dim, d)

  r.rg.draw(g, G.hit, G.hit + 110, ...Object.values(s.phoneToFrame(540, 450)))
  const from = s.deskToFrame(40 + CELL * 30, rowY(ROW.notify) + LINE / 2)
  r.a.draw(g, G.arcN, from, s.phoneToFrame(540, 259))

  show(r.black, 1 - clamp(g / 12))
}
