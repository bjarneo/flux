// The split frame of the storyboard (storyboard.json, style.home_layout):
// the Omarchy desktop in a 16:10 pane on the left, the phone on the right,
// and the captions under the pane. Every scene from s01 to s16 uses it, so
// the cuts match.

import { h, css, place } from '../dom.js'
import { C, FONT, DESK, PHONE } from '../tokens.js'
import { clamp, ease, interp, lerp, FPS } from '../anim.js'
import { desktop } from './desktop.js'
import { phone } from './phone.js'
import { caption, reveal } from './text.js'

export const PANE = { x: 64, y: 56, w: 1264, h: 790 }
export const PANE_S = PANE.w / DESK.w // 0.877778 at zoom 1
export const PHONE_AT = { x: 1438, y: 56, s: 0.366667 }
export const SCREEN_AT = { x: 1449, y: 67, s: 0.366667 }

/** Named shots: z, cx, cy in desk px. */
export const SHOT = {
  WIDE: { z: 1.0, cx: 720, cy: 450 },
  HERO: { z: 2.2, cx: 327.27, cy: 204.55 },
  'HERO+': { z: 2.28, cx: 315.79, cy: 197.37 },
  RT: { z: 1.8, cx: 1040, cy: 250 },
  MPV: { z: 1.3, cx: 720, cy: 463 },
  BAR: { z: 4.0, cx: 1260, cy: 112.5 },
  PANEL: { z: 1.4, cx: 925.71, cy: 321.43 },
  PANEL_WIDE: { z: 1.1, cx: 785.45, cy: 435.09 },
  MIC: { z: 1.35, cx: 906.67, cy: 390 },
  PAIR: { z: 2.2, cx: 457.27, cy: 287.55 },
  CARD_TIGHT: { z: 2.6, cx: 1163.08, cy: 173.08 },
}

/** The IP patch for live captures that read 'Omarchy · 127.0.0.1'. */
export const IP_PATCH = { x: 146, y: 229, w: 414, h: 41, fill: '#121318', text: 'Omarchy · 192.168.1.20', left: 150, baseline: 258, size: 31.5, color: '#c4c6d0' }

/** Clamps a camera so that no desktop edge shows in the pane. */
function clampCam(z, cx, cy) {
  const S = PANE_S * z
  const hw = PANE.w / 2 / S, hh = PANE.h / 2 / S
  return { z, S, cx: clamp(cx, hw, DESK.w - hw), cy: clamp(cy, hh, DESK.h - hh) }
}

/**
 * Builds the split frame into layer. opts: wallpaper, next, bar (options
 * for the bar), screens (phone screens, see phone()).
 * Returns: root, pane, desk (the desktop() object), phone, overlay (frame
 * px, above everything), and the methods below.
 */
export function split(layer, { wallpaper = '3-sunset-lake', next = null, bar = {}, screens = {} } = {}) {
  const root = h('div', {
    style: {
      position: 'absolute', inset: 0, overflow: 'hidden', background: `radial-gradient(900px 900px at 1647px 507px, rgba(122,162,247,0.06), transparent 70%),
        radial-gradient(1200px 760px at 696px 451px, rgba(122,162,247,0.035), transparent 70%), #0e0e14`,
    },
  })
  // The pane: a 1 px outline just outside it and a soft shadow.
  const outline = h('div', {
    style: {
      position: 'absolute', left: PANE.x - 1, top: PANE.y - 1, width: PANE.w + 2, height: PANE.h + 2,
      border: `1px solid ${C.bg3}`, boxShadow: '0 24px 60px rgba(0,0,0,0.45)', boxSizing: 'border-box',
    },
  })
  const pane = h('div', { style: { position: 'absolute', left: PANE.x, top: PANE.y, width: PANE.w, height: PANE.h, overflow: 'hidden', background: C.bg } })
  const desk = desktop({ wallpaper, next, clock: 'Saturday 09:41', ...bar })
  // The battery glyph for 64 percent on battery.
  const batt = desk.bar.el.lastChild && [...desk.bar.el.querySelectorAll('span')].find((s) => s.textContent === String.fromCodePoint(0xf0079))
  if (batt) batt.textContent = String.fromCodePoint(0xf0080)
  pane.append(desk.el)

  const p = phone(screens)
  place(p.el, PHONE_AT)
  const overlay = h('div', { style: { position: 'absolute', inset: 0, pointerEvents: 'none', zIndex: 20 } })
  root.append(outline, pane, p.el, overlay)
  layer.append(root)

  let cam = clampCam(1, 720, 450)
  const applyCam = () => {
    desk.el.style.transformOrigin = '0 0'
    desk.el.style.transform = `translate(${PANE.w / 2 - cam.cx * cam.S}px, ${PANE.h / 2 - cam.cy * cam.S}px) scale(${cam.S})`
  }
  applyCam()

  return {
    root, pane, desk, phone: p, overlay,

    /** Sets the pane camera: zoom z, desk point cx, cy at the pane center. */
    cam(z, cx, cy) {
      cam = clampCam(z, cx, cy)
      applyCam()
      return cam
    },

    /** Sets the camera from a named shot. */
    shot(name) {
      const s = SHOT[name]
      return this.cam(s.z, s.cx, s.cy)
    },

    /**
     * Moves the camera through keys [{ f, shot } or { f, z, cx, cy }] with
     * ease.camera. The zoom moves in log space.
     */
    camKeys(keys, f) {
      const ks = keys.map((k) => (k.shot ? { f: k.f, ...SHOT[k.shot] } : k))
      const fr = ks.map((k) => k.f)
      const z = Math.exp(interp(f, fr, ks.map((k) => Math.log(k.z)), ease.camera))
      const cx = interp(f, fr, ks.map((k) => k.cx), ease.camera)
      const cy = interp(f, fr, ks.map((k) => k.cy), ease.camera)
      return this.cam(z, cx, cy)
    },

    /** A desk point in frame px for the current camera. */
    deskToFrame(x, y) {
      return { x: PANE.x + PANE.w / 2 + (x - cam.cx) * cam.S, y: PANE.y + PANE.h / 2 + (y - cam.cy) * cam.S }
    },

    /** A phone capture point in frame px, with the phone at rest. */
    phoneToFrame(u, v, dx = 0, dy = 0) {
      return { x: SCREEN_AT.x + SCREEN_AT.s * u + dx, y: SCREEN_AT.y + SCREEN_AT.s * v + dy }
    },

    /**
     * Shakes the phone like a vibration from frame start for frames n:
     * 2.5 px at 24 Hz, 0.5 s on and 0.25 s off.
     */
    vibrate(f, start, n) {
      const t = (f - start) / FPS
      let dx = 0
      if (f >= start && f < start + n && t % 0.75 < 0.5) dx = 2.5 * Math.sin(2 * Math.PI * 24 * t)
      place(p.el, { ...PHONE_AT, x: PHONE_AT.x + dx })
      return dx
    },
  }
}

/**
 * The caption block under the pane: kicker and title, a sub line that can
 * start later, and an optional direction label under the phone, such as
 * 'Phone → Desktop'. update(f, start, end, subStart).
 */
export function captions(layer, { kicker = '', title, sub = '', dir = '' }) {
  const cap = caption({ kicker, title, x: PANE.x, y: 872, width: PANE.w, size: 52 })
  const subEl = sub ? reveal(sub, { left: PANE.x, top: 987, width: PANE.w, fontWeight: 450, fontSize: 24, color: C.inkDim, letterSpacing: '-0.005em', lineHeight: '1.35' }, { stagger: 2, dur: 30 }) : null
  // Words that look like paths or commands use the mono font.
  if (subEl) for (const w of subEl.words) if (/[~/]|flux|omarchy-|mpv|sudo/.test(w.textContent) && /[~/.-]/.test(w.textContent)) css(w, { fontFamily: FONT.mono, fontSize: 22, color: C.fg })
  const dirEl = dir ? h('div', {
    style: {
      position: 'absolute', left: PHONE_AT.x, width: 418, top: 990, textAlign: 'center', fontFamily: FONT.mono, fontSize: 16,
      color: C.fgDark, whiteSpace: 'nowrap', visibility: 'hidden',
    },
    html: dir.replace(/(→|←|↔)/g, `<span style="color:${C.accent}">$1</span>`),
  }) : null
  layer.append(cap.el)
  if (subEl) layer.append(subEl.el)
  if (dirEl) layer.append(dirEl)
  return {
    update(f, start, end, subStart = start + 12) {
      cap.update(f, start, end)
      subEl && subEl.update(f, subStart, end)
      if (dirEl) {
        const o = Math.min(clamp((f - start) / 18), 1 - clamp((f - (end - 16)) / 16))
        place(dirEl, { o, y: -Math.max(0, f - (end - 16)) / 16 * 14 })
      }
    },
  }
}

/**
 * The flux arc: a 2 px accent curve from a to b in frame px, bent toward the
 * top by 14 percent of its length, drawn over 17 frames with a glowing dot,
 * then faded over 12 frames. draw(f, start, a, b).
 */
export function arc(layer) {
  const svg = h('svg', { width: 1920, height: 1080, viewBox: '0 0 1920 1080', style: 'position:absolute;left:0;top:0;overflow:visible;pointer-events:none;z-index:30' })
  const defs = h('defs', {}, h('filter', { id: 'arcglow', x: '-200%', y: '-200%', width: '500%', height: '500%' }, h('feGaussianBlur', { stdDeviation: 5 })))
  const path = h('path', { fill: 'none', stroke: C.accent, 'stroke-width': 2, 'stroke-linecap': 'round' })
  const glow = h('circle', { r: 9, fill: 'rgba(122,162,247,0.9)', filter: 'url(#arcglow)' })
  const dot = h('circle', { r: 3.5, fill: C.fgBright })
  svg.append(defs, path, glow, dot)
  layer.append(svg)
  return {
    draw(f, start, a, b) {
      const t = f - start
      if (t < 0 || t > 29) { svg.style.visibility = 'hidden'; return }
      svg.style.visibility = 'visible'
      const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
      const len = Math.hypot(b.x - a.x, b.y - a.y)
      const c = { x: mx, y: my - 0.14 * len }
      path.setAttribute('d', `M ${a.x} ${a.y} Q ${c.x} ${c.y} ${b.x} ${b.y}`)
      const total = path.getTotalLength()
      const p = ease.outCubic(clamp(t / 17))
      path.setAttribute('stroke-dasharray', `${total}`)
      path.setAttribute('stroke-dashoffset', `${total * (1 - p)}`)
      const q = path.getPointAtLength(total * p)
      for (const el of [glow, dot]) { el.setAttribute('cx', q.x); el.setAttribute('cy', q.y) }
      const fade = 1 - clamp((t - 17) / 12)
      svg.style.opacity = String(fade)
    },
  }
}

/** Expanding accent rings at frame px x, y: a new ring every 0.45 s. */
export function rings(layer) {
  const els = [0, 1].map(() => {
    const d = h('div', { style: { position: 'absolute', width: 120, height: 120, marginLeft: -60, marginTop: -60, borderRadius: 60, border: `2px solid ${C.accent}`, visibility: 'hidden', zIndex: 25 } })
    layer.append(d)
    return d
  })
  return {
    draw(f, start, end, x, y) {
      els.forEach((d, i) => {
        const t = (f - start) / FPS - i * 0.45
        if (f < start || f >= end || t < 0) { d.style.visibility = 'hidden'; return }
        const q = (t % 0.9) / 0.6
        if (q > 1) { d.style.visibility = 'hidden'; return }
        css(d, { left: x, top: y })
        place(d, { s: q, o: 0.5 * (1 - q) })
      })
    },
  }
}
