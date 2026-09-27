// Small shared pieces: the stage background, the Flux mark, the cursor,
// click rings, and a camera (world transform) helper.

import { h, css, place } from '../dom.js'
import { C } from '../tokens.js'
import { clamp, ease, lerp, interp } from '../anim.js'

/** The dark stage behind the desktop and the phone, 1920x1080. */
export function stageBg() {
  const el = h('div', {
    style: {
      position: 'absolute', inset: 0, overflow: 'hidden',
      background: `radial-gradient(1200px 800px at 70% 20%, rgba(122,162,247,0.10), rgba(122,162,247,0) 60%),
        radial-gradient(900px 700px at 15% 90%, rgba(173,142,230,0.08), rgba(173,142,230,0) 60%),
        linear-gradient(180deg, #0d0e15 0%, #0a0b10 100%)`,
    },
  })
  // A faint 48 px grid, like graph paper, fading at the edges.
  const grid = h('div', {
    style: {
      position: 'absolute', inset: 0, opacity: '0.35',
      backgroundImage: 'linear-gradient(rgba(169,177,214,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(169,177,214,0.05) 1px, transparent 1px)',
      backgroundSize: '48px 48px',
      maskImage: 'radial-gradient(ellipse at center, black 30%, transparent 75%)',
      webkitMaskImage: 'radial-gradient(ellipse at center, black 30%, transparent 75%)',
    },
  })
  el.append(grid)
  return { el }
}

/**
 * The Flux mark on the 16-unit grid: a square ring 10 units wide at 3 with
 * a 2-unit stroke, and a bar 2 by 14 units at 7, 1 over the ring.
 * draw(p) builds it: the ring traces in, then the bar drops through.
 */
export function fluxMark(size = 160, { fg = C.fgBright, accent = C.accent } = {}) {
  const u = size / 16
  const el = h('div', { style: { position: 'absolute', width: size, height: size } })
  // The ring as 4 sides that grow in order.
  const sides = [
    { x: 3, y: 3, w: 10, h: 2, dir: 'x' },
    { x: 11, y: 3, w: 2, h: 10, dir: 'y' },
    { x: 3, y: 11, w: 10, h: 2, dir: 'x', rev: true },
    { x: 3, y: 3, w: 2, h: 10, dir: 'y', rev: true },
  ].map((s) => {
    const d = h('div', { style: { position: 'absolute', left: s.x * u, top: s.y * u, width: s.w * u, height: s.h * u, background: fg, transformOrigin: s.rev ? (s.dir === 'x' ? '100% 50%' : '50% 100%') : (s.dir === 'x' ? '0 50%' : '50% 0') } })
    el.append(d)
    return { d, ...s }
  })
  const bar = h('div', { style: { position: 'absolute', left: 7 * u, top: 1 * u, width: 2 * u, height: 14 * u, background: accent, transformOrigin: '50% 0' } })
  el.append(bar)
  return {
    el,
    /** p in 0..1: 0 to 0.7 traces the ring, 0.55 to 1 drops the bar. */
    draw(p) {
      sides.forEach((s, i) => {
        const q = ease.inOutCubic(clamp((p / 0.7) * 4 - i))
        s.d.style.transform = s.dir === 'x' ? `scaleX(${q})` : `scaleY(${q})`
      })
      const b = ease.outQuint(clamp((p - 0.55) / 0.45))
      bar.style.transform = `scaleY(${b})`
    },
  }
}

/** The pointer: a white arrow with a dark outline, 24 px tall. */
export function cursor() {
  const svg = h('svg', { width: 26, height: 30, viewBox: '0 0 26 30', style: 'position:absolute;left:0;top:0;overflow:visible;filter:drop-shadow(0 2px 3px rgba(0,0,0,0.45))' },
    h('path', { d: 'M2 2 L2 23 L7.5 17.8 L11.2 26.5 L15 24.8 L11.4 16.4 L19 16.4 Z', fill: '#ffffff', stroke: '#111', 'stroke-width': 1.6, 'stroke-linejoin': 'round' }))
  const ring = h('div', { style: { position: 'absolute', width: 36, height: 36, marginLeft: -18, marginTop: -18, borderRadius: 18, border: `2px solid ${C.accent}`, visibility: 'hidden' } })
  const el = h('div', { style: { position: 'absolute', left: 0, top: 0, width: 1, height: 1, zIndex: 100 } }, ring, svg)
  return {
    el,
    /** Moves the tip to x, y. click: frames since a click, or -1. */
    at(x, y, click = -1, o = 1) {
      el.style.transform = `translate(${x}px, ${y}px)`
      el.style.opacity = String(o)
      el.style.visibility = o > 0.001 ? 'visible' : 'hidden'
      if (click >= 0 && click < 24) {
        const p = click / 24
        place(ring, { s: 0.4 + 1.2 * ease.outCubic(p), o: 1 - p })
        svg.style.transform = `scale(${click < 6 ? 0.9 : 1})`
      } else {
        ring.style.visibility = 'hidden'
        svg.style.transform = 'scale(1)'
      }
    },
  }
}

/**
 * A path for the cursor through points [{ f, x, y }] with smooth moves.
 * Returns { x, y } at frame f.
 */
export function path(points, f) {
  return { x: interp(f, points.map((p) => p.f), points.map((p) => p.x), ease.inOutCubic), y: interp(f, points.map((p) => p.f), points.map((p) => p.y), ease.inOutCubic) }
}

/**
 * A camera over a world container. keys: [{ f, x, y, s }] where x, y is the
 * world point at the frame center, s is the zoom. Returns the transform.
 */
export function camera(world, keys, f, W = 1920, H = 1080) {
  const fr = keys.map((k) => k.f)
  const cx = interp(f, fr, keys.map((k) => k.x), ease.camera)
  const cy = interp(f, fr, keys.map((k) => k.y), ease.camera)
  // Interpolate the zoom in log space, so zoom speed feels even.
  const s = Math.exp(interp(f, fr, keys.map((k) => Math.log(k.s)), ease.camera))
  world.style.transformOrigin = '0 0'
  world.style.transform = `translate(${W / 2 - cx * s}px, ${H / 2 - cy * s}px) scale(${s})`
  return { cx, cy, s }
}
