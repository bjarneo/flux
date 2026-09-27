// A generic modern Android phone. The screen uses the capture coordinates,
// 1080x2400 px, so overlays line up with the real screenshots.

import { h, css, place } from '../dom.js'
import { C, PHONE } from '../tokens.js'
import { clamp, FPS, ease } from '../anim.js'

export const BODY = { bezel: 30, w: PHONE.w + 60, h: PHONE.h + 60, radius: 132, screenRadius: 104 }

/**
 * A phone. screens maps names to image srcs of 1080x2400 captures.
 * Place the phone with place(phone.el, { x, y, s }). At s = 0.35 the phone
 * is 399x861 px. The transform origin is the top left corner.
 * Returns: el, screen (1080x2400 box), overlay (above the screens, in
 * screen px), show(weights), tap(x, y, f, start).
 */
export function phone(screens = {}) {
  const el = h('div', {
    style: { position: 'absolute', left: 0, top: 0, width: BODY.w, height: BODY.h, transformOrigin: '0 0' },
  })
  // Side buttons on the right edge.
  const btn = (top, height) => h('div', {
    style: {
      position: 'absolute', left: BODY.w - 4, top, width: 12, height, borderRadius: 6,
      background: 'linear-gradient(90deg, #2a2c36, #3b3e4c 60%, #22242c)',
    },
  })
  el.append(btn(560, 190), btn(820, 330))
  const body = h('div', {
    style: {
      position: 'absolute', inset: 0, borderRadius: BODY.radius,
      background: 'linear-gradient(145deg, #2f3240 0%, #16171d 40%, #0d0e12 100%)',
      boxShadow: 'inset 0 0 0 3px #3c4050, inset 0 0 0 7px #0b0c10, 0 60px 120px rgba(0,0,0,0.55), 0 20px 40px rgba(0,0,0,0.35)',
    },
  })
  const screen = h('div', {
    style: {
      position: 'absolute', left: BODY.bezel, top: BODY.bezel, width: PHONE.w, height: PHONE.h,
      borderRadius: BODY.screenRadius, overflow: 'hidden', background: '#000',
    },
  })
  // A screen is an image src, or { src, patches: [...] }. A patch covers a
  // capture rect { x, y, w, h, fill } and can draw text { text, left, baseline,
  // size, color, font, weight } on it. Patches show and hide with their screen.
  const imgs = {}
  for (const [name, spec] of Object.entries(screens)) {
    const src = typeof spec === 'string' ? spec : spec.src
    const wrap = h('div', { style: { position: 'absolute', left: 0, top: 0, width: PHONE.w, height: PHONE.h, visibility: 'hidden' } })
    wrap.append(h('img', { src, style: { position: 'absolute', left: 0, top: 0, width: PHONE.w, height: PHONE.h } }))
    for (const pt of (typeof spec === 'string' ? [] : spec.patches || [])) {
      wrap.append(h('div', { style: { position: 'absolute', left: pt.x, top: pt.y, width: pt.w, height: pt.h, background: pt.fill || '#121318' } }))
      if (pt.text) {
        const size = pt.size || 31.5
        wrap.append(h('div', {
          style: {
            position: 'absolute', left: pt.left ?? pt.x, top: (pt.baseline ?? pt.y + pt.h * 0.75) - size * 0.93, fontSize: size,
            lineHeight: `${size * 1.2}px`, color: pt.color || '#c4c6d0', fontFamily: pt.font || "'Roboto', sans-serif",
            fontWeight: String(pt.weight || 400), whiteSpace: 'nowrap',
          },
          text: pt.text,
        }))
      }
    }
    imgs[name] = wrap
    screen.append(wrap)
  }
  const overlay = h('div', { style: { position: 'absolute', left: 0, top: 0, width: PHONE.w, height: PHONE.h } })
  // The punch-hole camera over the status bar.
  const hole = h('div', {
    style: {
      position: 'absolute', left: PHONE.w / 2 - 22, top: 38, width: 44, height: 44, borderRadius: 22,
      background: 'radial-gradient(circle at 35% 35%, #2b3140 0%, #07080b 55%)', boxShadow: '0 0 0 3px #050507',
    },
  })
  // A faint glass reflection.
  const glass = h('div', {
    style: {
      position: 'absolute', inset: 0, pointerEvents: 'none',
      background: 'linear-gradient(115deg, rgba(255,255,255,0.05) 0%, rgba(255,255,255,0) 35%)',
    },
  })
  screen.append(overlay, hole, glass)
  el.append(body, screen)

  const ripple = h('div', {
    style: {
      position: 'absolute', width: 120, height: 120, marginLeft: -60, marginTop: -60, borderRadius: 60,
      background: 'rgba(255,255,255,0.35)', border: '3px solid rgba(255,255,255,0.8)', visibility: 'hidden',
    },
  })
  overlay.append(ripple)

  return {
    el, screen, overlay, imgs,
    /** Sets the opacity of each named screen. Screens not named get 0. */
    show(weights) {
      for (const [name, img] of Object.entries(imgs)) {
        const o = weights[name] || 0
        img.style.opacity = String(o)
        img.style.visibility = o > 0.001 ? 'visible' : 'hidden'
      }
    },
    /**
     * A touch indicator at x, y in screen px. It presses in from frame start,
     * holds briefly, and fades. Call it every frame. Returns true while visible.
     */
    tap(x, y, f, start, hold = 10) {
      const t = f - start
      const total = 10 + hold + 16
      if (t < 0 || t > total) { ripple.style.visibility = 'hidden'; return false }
      const inP = clamp(t / 10)
      const outP = clamp((t - 10 - hold) / 16)
      const s = 0.6 + 0.4 * ease.outCubic(inP) + 0.3 * outP
      css(ripple, { left: x, top: y })
      place(ripple, { s, o: (1 - outP) * (0.4 + 0.6 * inP) })
      return true
    },
  }
}

/** A dark screen dim for dialogs over a screen, in screen px. */
export function scrim(opacity = 0.5) {
  return h('div', { style: { position: 'absolute', inset: 0, background: `rgba(0,0,0,${opacity})`, visibility: 'hidden' } })
}
