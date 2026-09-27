// The Omarchy desktop at 1440x900 logical px: wallpaper, the omarchy-shell
// top bar, a window layer, and a notification layer. Values come from the
// live Tokyo Night theme and the omarchy-shell source (survey.json, look).

import { h, css, place } from '../dom.js'
import { C, FONT, DESK } from '../tokens.js'

const G = (cp) => String.fromCodePoint(cp)

export const WALL = (name) => `assets/wallpapers/${name}.jpg`

/** The Flux bar mark: a 14 px box with a square ring and a vertical bar. */
export function barMark(online = true) {
  const ring = h('rect', { x: 3.5, y: 3.5, width: 7, height: 7, fill: 'none', stroke: C.fg, 'stroke-width': 1 })
  const bar = h('rect', { x: 6, y: 1, width: 2, height: 12, fill: online ? C.accent : C.fg })
  const svg = h('svg', { width: 14, height: 14, viewBox: '0 0 14 14', style: 'display:block;shape-rendering:crispEdges' }, ring, bar)
  return { el: svg, bar, setOnline: (on) => bar.setAttribute('fill', on ? C.accent : C.fg) }
}

function slot(width, child, extra = {}) {
  return h('div', {
    style: {
      width, height: DESK.bar, display: 'flex', alignItems: 'center', justifyContent: 'center',
      flex: 'none', ...extra,
    },
  }, child)
}

function glyph(cp, size = 13, extra = {}) {
  return h('span', { style: { fontFamily: FONT.mono, fontSize: size, lineHeight: '1', color: C.fg, ...extra }, text: G(cp) })
}

/**
 * The omarchy-shell bar. clock is the text in the center, for example
 * "Saturday 09:41". focused is the focused workspace, 1 to 5.
 */
export function bar({ clock = 'Saturday 09:41', focused = 1, occupied = [1, 2], fluxOnline = true } = {}) {
  const el = h('div', {
    style: {
      position: 'absolute', left: 0, top: 0, width: DESK.w, height: DESK.bar, background: C.bg,
      color: C.fg, fontFamily: FONT.mono, fontSize: 12, zIndex: 50,
    },
  })

  // Left: the Omarchy menu glyph and the kanji workspaces.
  const left = h('div', { style: { position: 'absolute', left: 8, top: 0, height: DESK.bar, display: 'flex', alignItems: 'center' } })
  left.append(slot(27, h('span', { style: { fontFamily: FONT.omarchy, fontSize: 12, color: C.fg, lineHeight: '1' }, text: G(0xe900) })))
  const kanji = ['一', '二', '三', '四', '五']
  const ws = h('div', { style: { display: 'flex', gap: 1, marginRight: 1.5 } })
  kanji.forEach((k, i) => {
    const n = i + 1
    const isFocused = n === focused
    const txt = isFocused
      ? h('span', { style: { fontFamily: FONT.mono, fontSize: 12, lineHeight: '1', color: C.fg }, text: G(0xf14fb) })
      : h('span', { style: { fontFamily: FONT.cjk, fontSize: 12, lineHeight: '1', color: C.fg, opacity: occupied.includes(n) ? 1 : 0.5 }, text: k })
    ws.append(slot(20, txt))
  })
  left.append(ws)

  // Center: the clock at the exact center, the keyboard layout to its right.
  const kb = h('div', {
    style: { position: 'absolute', left: '100%', top: 0, height: DESK.bar, lineHeight: `${DESK.bar}px`, fontSize: 10, padding: '0 6px' },
    text: 'EN',
  })
  const clockText = h('span', { text: clock })
  const clockEl = h('div', { style: { position: 'relative', padding: '0 8.5px', whiteSpace: 'nowrap', lineHeight: `${DESK.bar}px` } }, clockText, kb)
  const center = h('div', {
    style: { position: 'absolute', left: DESK.w / 2, top: 0, height: DESK.bar, transform: 'translateX(-50%)', display: 'flex' },
  }, clockEl)

  // Right: Flux, bluetooth, network, audio, battery.
  const right = h('div', { style: { position: 'absolute', right: 8, top: 0, height: DESK.bar, display: 'flex', alignItems: 'center' } })
  const mark = barMark(fluxOnline)
  const fluxSlot = slot(31, mark.el)
  right.append(
    fluxSlot,
    slot(27, glyph(0xf00af)),
    slot(27, glyph(0xf0928)),
    slot(27, glyph(0xf028)),
    slot(27, glyph(0xf0079)),
  )

  el.append(left, center, right)

  // The Flux tooltip, 6 px under the widget.
  const tip = h('div', {
    style: {
      position: 'absolute', top: DESK.bar + 6, background: 'rgba(26,27,38,0.97)', border: `1px solid ${C.fg}`,
      color: C.fg, fontFamily: FONT.mono, fontSize: 11, lineHeight: '15px', padding: '6px 10px', whiteSpace: 'pre',
      visibility: 'hidden', zIndex: 60,
    },
  })
  el.append(tip)

  // The Flux slot center in desk px: right edge 8, then 4 slots of 27, then half of 31.
  const fluxCenterX = DESK.w - 8 - 4 * 27 - 31 / 2

  return {
    el, mark, fluxSlot, tip, fluxCenterX, clockEl,
    setClock: (t) => { clockText.textContent = t },
    /** Shows the tooltip with text at opacity o, centered under the Flux mark. */
    tooltip(text, o) {
      if (tip.textContent !== text) tip.textContent = text
      const w = tip.offsetWidth
      tip.style.left = `${fluxCenterX - w / 2}px`
      place(tip, { o })
    },
  }
}

/**
 * The desktop. Returns layers in desk px: windows, notifs, overlay.
 * setWipe(p) reveals the next wallpaper with the omarchy-shell wipe:
 * a slanted parallelogram that grows from the center line.
 */
export function desktop({ wallpaper = '3-sunset-lake', next = '4-omakub', ...barOpts } = {}) {
  const el = h('div', {
    style: { position: 'absolute', left: 0, top: 0, width: DESK.w, height: DESK.h, overflow: 'hidden', background: C.bg, transformOrigin: '0 0' },
  })
  const imgStyle = { position: 'absolute', left: 0, top: 0, width: DESK.w, height: DESK.h, objectFit: 'cover' }
  const wallA = h('img', { src: WALL(wallpaper), style: imgStyle })
  const wallB = next ? h('img', { src: WALL(next), style: { ...imgStyle, clipPath: 'polygon(0 0,0 0,0 0,0 0)' } }) : null
  const windows = h('div', { style: { position: 'absolute', inset: 0 } })
  const notifs = h('div', { style: { position: 'absolute', inset: 0, zIndex: 70 } })
  const overlay = h('div', { style: { position: 'absolute', inset: 0, zIndex: 80 } })
  const b = bar(barOpts)
  el.append(wallA, ...(wallB ? [wallB] : []), windows, b.el, notifs, overlay)

  return {
    el, windows, notifs, overlay, bar: b, wallA, wallB,
    setWipe(p) {
      if (!wallB) return
      if (p <= 0) { wallB.style.clipPath = 'polygon(0 0,0 0,0 0,0 0)'; return }
      // At 1440x900 the center line runs from x=801 at the top to x=639 at the bottom.
      const lean = 0.09 * DESK.h
      const cx = DESK.w / 2
      const hw = p * (DESK.w / 2 + lean + 2)
      wallB.style.clipPath = `polygon(${cx + lean - hw}px 0, ${cx + lean + hw}px 0, ${cx - lean + hw}px ${DESK.h}px, ${cx - lean - hw}px ${DESK.h}px)`
    },
  }
}
