// Hyprland windows, the Ghostty terminal, and omarchy-shell notification
// cards, in desk px (1440x900). Values come from survey.json, look.

import { h, css, place } from '../dom.js'
import { C, FONT, DESK, hyprQuint } from '../tokens.js'
import { clamp, FPS } from '../anim.js'

const G = (cp) => String.fromCodePoint(cp)

/**
 * A Hyprland window. x, y, w, h are the border box in desk px: a 2 px
 * border, square corners, no titlebar, no shadow.
 */
export function hyprWindow({ x, y, w, h: hh, active = true, bg = C.bg, opacity = 0.985 } = {}) {
  const el = h('div', {
    style: {
      position: 'absolute', left: x, top: y, width: w, height: hh, border: `${DESK.border}px solid ${active ? C.accent : C.borderInactive}`,
      background: bg, overflow: 'hidden', transformOrigin: '50% 50%',
    },
  })
  const content = h('div', { style: { position: 'absolute', inset: 0, overflow: 'hidden', opacity: String(opacity) } })
  el.append(content)
  return {
    el, content,
    setActive: (on) => { el.style.borderColor = on ? C.accent : C.borderInactive },
    frame: { x, y, w, h: hh },
  }
}

/**
 * The Hyprland windowsIn animation: popin from 87% with easeOutQuint over
 * 410 ms, and a fade over 173 ms. Returns { s, o } for frame f.
 */
export function popin(f, start) {
  const t = (f - start) / FPS
  if (t <= 0) return { s: 0.87, o: 0 }
  const s = 0.87 + 0.13 * hyprQuint(clamp(t / 0.41))
  const o = clamp(t / 0.173)
  return { s, o }
}

/** The windowsOut animation: popin to 87% over 149 ms, linear. */
export function popout(f, start) {
  const t = (f - start) / FPS
  if (t <= 0) return { s: 1, o: 1 }
  const p = clamp(t / 0.149)
  return { s: 1 - 0.13 * p, o: 1 - p }
}

/**
 * A stack of images of the same size, for UI states. show({name: opacity})
 * sets the opacity of each. Images not named get 0.
 */
export function imageStack(srcs, w, hh) {
  const el = h('div', { style: { position: 'absolute', left: 0, top: 0, width: w, height: hh } })
  const imgs = {}
  for (const [name, src] of Object.entries(srcs)) {
    const img = h('img', { src, style: { position: 'absolute', left: 0, top: 0, width: w, height: hh, opacity: '0' } })
    imgs[name] = img
    el.append(img)
  }
  return {
    el, imgs,
    show(weights) {
      for (const [name, img] of Object.entries(imgs)) {
        const o = weights[name] || 0
        img.style.opacity = String(o)
        img.style.visibility = o > 0.001 ? 'visible' : 'hidden'
      }
    },
  }
}

// ---------------------------------------------------------------------------
// Ghostty with the Starship prompt.

export const TERM = { font: 12, line: 16, pad: 19, cell: 7.2 }

/** Segments for the Starship prompt in the Flux repo or in home. */
export function prompt(where = 'repo') {
  if (where === 'home') return [{ t: '~ ', c: C.cyan, b: true }, { t: '❯ ', c: C.cyan, b: true }]
  return [
    { t: 'omarchy-flux ', c: C.cyan, b: true },
    { t: 'main ', c: C.cyan, i: true },
    { t: '❯ ', c: C.cyan, b: true },
  ]
}

/**
 * A Ghostty terminal body. render(lines, cursor) draws lines, where each
 * line is an array of segments { t, c, b, i, bg }. cursor is null or
 * { line, col } with a block cursor.
 */
export function terminal({ w, h: hh, font = TERM.font, lineH = TERM.line, pad = TERM.pad } = {}) {
  const el = h('div', {
    style: {
      position: 'absolute', inset: 0, background: C.bg, color: C.fg, fontFamily: FONT.mono, fontSize: font,
      lineHeight: `${lineH}px`, padding: `${pad}px`, whiteSpace: 'pre', overflow: 'hidden',
    },
  })
  let last = ''
  return {
    el,
    render(lines, cursor = null) {
      const key = JSON.stringify([lines, cursor])
      if (key === last) return
      last = key
      el.textContent = ''
      lines.forEach((segs, li) => {
        const row = h('div', { style: { height: lineH, position: 'relative' } })
        let col = 0
        for (const s of segs) {
          const span = h('span', {
            style: {
              color: s.c || C.fg, fontWeight: s.b ? '700' : '400', fontStyle: s.i ? 'italic' : 'normal',
              background: s.bg || 'transparent',
            },
            text: s.t,
          })
          row.append(span)
          col += [...s.t].length
        }
        if (cursor && cursor.line === li) {
          const cx = cursor.col ?? col
          row.append(h('span', {
            style: {
              position: 'absolute', left: `calc(${cx}ch)`, top: 0, width: '1ch', height: lineH,
              background: C.fgBright, opacity: cursor.on === false ? '0' : '1',
            },
          }))
        }
        el.append(row)
      })
    },
  }
}

// ---------------------------------------------------------------------------
// omarchy-shell notification cards.

export const NOTIF = { w: 380, x: DESK.w - 5 - 380, y: DESK.bar + 5, gap: 8 }

/**
 * A notification card. icon is an element for the 40x40 slot, or an image
 * src. summary and body are strings.
 */
export function notification({ summary, body = '', icon = null, img = null }) {
  const el = h('div', {
    style: {
      position: 'absolute', left: NOTIF.x, top: NOTIF.y, width: NOTIF.w, background: C.bg,
      border: `2px solid ${C.accent}`, padding: '10px 12px', display: 'flex', alignItems: 'center', gap: 12,
      fontFamily: FONT.notif, visibility: 'hidden', transformOrigin: '100% 0',
    },
  })
  let slotEl = null
  if (img) {
    slotEl = h('div', { style: { width: 40, height: 40, flex: 'none', display: 'flex', alignItems: 'center', justifyContent: 'center' } },
      h('img', { src: img, style: { maxWidth: 40, maxHeight: 40, objectFit: 'contain' } }))
  } else if (icon) {
    slotEl = h('div', { style: { width: 40, height: 40, flex: 'none' } }, icon)
  }
  const text = h('div', { style: { flex: 1, minWidth: 0, marginRight: 10 } },
    h('div', { style: { fontSize: 14, fontWeight: 700, color: C.fg, lineHeight: '18px', overflowWrap: 'anywhere', display: '-webkit-box', webkitLineClamp: '2', webkitBoxOrient: 'vertical', overflow: 'hidden' }, text: summary }),
    body ? h('div', { style: { fontSize: 14, color: C.notifBody, lineHeight: '18px', marginTop: 2, overflowWrap: 'anywhere', display: '-webkit-box', webkitLineClamp: '3', webkitBoxOrient: 'vertical', overflow: 'hidden' }, text: body }) : null,
  )
  if (slotEl) el.append(slotEl)
  el.append(text)
  return { el }
}

/** The layersIn fade: 400 ms easeOutQuint. Returns the opacity. */
export function layerIn(f, start) {
  return hyprQuint(clamp((f - start) / (0.4 * FPS)))
}

/** The layersOut fade: 150 ms linear. */
export function layerOut(f, start) {
  return 1 - clamp((f - start) / (0.15 * FPS))
}

/** A rounded app icon for a notification slot: a colored tile with a glyph. */
export function appIcon(cp, color, size = 40) {
  return h('div', {
    style: {
      width: size, height: size, borderRadius: size * 0.28, background: color, display: 'flex',
      alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: FONT.mono, fontSize: size * 0.5,
    },
    text: G(cp),
  })
}
