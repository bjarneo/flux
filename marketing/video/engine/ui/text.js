// Marketing captions. Words rise out of a mask, one after the other.

import { h, css, place } from '../dom.js'
import { C, FONT } from '../tokens.js'
import { clamp, ease, FPS } from '../anim.js'

/**
 * A text block whose words reveal in order. Style keys go to the block.
 * update(f, start, end) reveals from start and hides before end.
 * Options: stagger (frames per word), dur (frames per word), out (frames).
 */
export function reveal(text, style = {}, { stagger = 3, dur = 34, out = 16, rise = 0.9 } = {}) {
  const el = h('div', {
    style: {
      position: 'absolute', fontFamily: FONT.sans, color: C.ink, fontWeight: 700, letterSpacing: '-0.02em',
      lineHeight: '1.08', whiteSpace: 'normal', ...style,
    },
  })
  const words = []
  const parts = String(text).split(/(\s+)/)
  for (const p of parts) {
    if (/^\s+$/.test(p)) { el.append(document.createTextNode(' ')); continue }
    if (!p) continue
    const inner = h('span', { style: { display: 'inline-block', willChange: 'auto' }, text: p })
    const mask = h('span', { style: { display: 'inline-block', overflow: 'hidden', verticalAlign: 'top', paddingBottom: '0.12em', marginBottom: '-0.12em' } }, inner)
    el.append(mask)
    words.push(inner)
  }
  return {
    el, words,
    update(f, start, end = Infinity) {
      const outP = end === Infinity ? 0 : ease.inCubic(clamp((f - (end - out)) / out))
      words.forEach((w, i) => {
        const p = ease.outQuint(clamp((f - start - i * stagger) / dur))
        w.style.transform = `translateY(${(1 - p) * rise * 100}%)`
        w.style.opacity = String(p)
      })
      el.style.opacity = String(1 - outP)
      el.style.transform = `translateY(${-outP * 14}px)`
      el.style.visibility = f < start || outP >= 1 ? 'hidden' : 'visible'
    },
  }
}

/**
 * The standard caption: a small kicker in mono accent, a title, and an
 * optional sub line. x, y is the top left corner in frame px.
 */
export function caption({ kicker = '', title, sub = '', x = 120, y = 120, width = 760, size = 64, align = 'left' }) {
  const el = h('div', { style: { position: 'absolute', left: x, top: y, width, textAlign: align } })
  const k = kicker ? reveal(kicker, {
    position: 'relative', fontFamily: FONT.mono, fontWeight: 500, fontSize: 18, letterSpacing: '0.08em',
    color: C.accent, textTransform: 'uppercase', marginBottom: 18,
  }, { stagger: 2, dur: 26 }) : null
  const t = reveal(title, { position: 'relative', fontSize: size, width }, { stagger: 4, dur: 36 })
  const s = sub ? reveal(sub, {
    position: 'relative', fontWeight: 450, fontSize: Math.round(size * 0.36), color: C.inkDim, letterSpacing: '-0.005em',
    lineHeight: '1.35', marginTop: 22, width,
  }, { stagger: 2, dur: 30 }) : null
  if (k) el.append(k.el)
  el.append(t.el)
  if (s) el.append(s.el)
  return {
    el,
    update(f, start, end = Infinity) {
      k && k.update(f, start, end)
      t.update(f, start + (k ? 6 : 0), end)
      s && s.update(f, start + (k ? 6 : 0) + 10, end)
    },
  }
}

/** A mono label chip, for commands such as "yay -S omarchy-flux". */
export function chip(text, style = {}) {
  return h('div', {
    style: {
      position: 'absolute', fontFamily: FONT.mono, fontSize: 26, color: C.fgBright, background: 'rgba(26,27,38,0.85)',
      border: `2px solid ${C.bg3}`, padding: '14px 22px', whiteSpace: 'pre', ...style,
    },
    text,
  })
}
