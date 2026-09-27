// The Android heads-up notification that Flux posts, in phone capture px
// (1080 wide). Append el to phone.overlay. The layout follows the heads-up
// of the earlier Flux video: a 1032 x 282 card at x 24, y 118, radius 60,
// with the app icon in a 96 px circle.
//
// Flux notifications show the app name, the computer as the subtext, and
// the time: 'Flux · omarchy-xps · now'. Titles and texts must match the
// strings of the app:
//   agent blocked   'codex in billing needs input'  text 'Run the database migration'
//   agent finished  'codex in billing finished'     text 'Run the database migration'
//   flux notify     the title and the body of the command

import { h, place } from '../dom.js'
import { clamp, ease, lerp } from '../anim.js'

/**
 * Returns { el, update(f, start, end) }. The card slides down over 18
 * frames from start and slides up over 12 frames from end. Outside that
 * range it is hidden.
 */
export function headsUp({ app = 'Flux', sub = 'omarchy-xps', time = 'now', title, text = '' }) {
  const el = h('div', {
    style: {
      position: 'absolute', left: 24, top: 118, width: 1032, height: 282, borderRadius: 60, background: '#282a2f',
      boxShadow: '0 18px 44px rgba(0,0,0,0.5)', overflow: 'hidden', visibility: 'hidden', zIndex: 5,
    },
  })
  // The small icon of Flux is the mark on a light circle.
  const icon = h('div', {
    style: {
      position: 'absolute', left: 48, top: 93, width: 96, height: 96, borderRadius: 48, background: '#b2c5ff',
      overflow: 'hidden',
    },
  })
  icon.append(h('img', { src: 'assets/misc/flux.svg', style: { position: 'absolute', left: 8, top: 8, width: 80, height: 80, borderRadius: 40 } }))
  const line = (t, size, weight, color, lh, mt = 0) => h('div', {
    style: {
      fontFamily: "'Roboto', sans-serif", fontSize: size, fontWeight: String(weight), color, lineHeight: `${lh}px`, marginTop: mt,
      whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
    },
    text: t,
  })
  const body = h('div', { style: { position: 'absolute', left: 180, top: text ? 71 : 94, width: 820 } },
    line(`${app} · ${sub} · ${time}`, 31.5, 400, '#c4c6d0', 40),
    line(title, 39, 500, '#e3e2e9', 48, 6),
  )
  if (text) body.append(line(text, 36.75, 400, '#c4c6d0', 46))
  el.append(icon, body)
  return {
    el,
    update(f, start, end = Infinity) {
      const down = ease.outQuint(clamp((f - start) / 18))
      const up = ease.inCubic(clamp((f - end) / 12))
      const y = lerp(-440, 0, down) - 440 * up
      place(el, { y, o: f >= start && up < 1 ? 1 : 0 })
    },
  }
}
