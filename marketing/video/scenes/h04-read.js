// h04-read: the codex output on the phone. The phone scales up and moves
// left so the dialog in color reads, and the desktop dims under it. In the
// break of the music the motion holds, and a pulse on the beat outlines
// '1 Yes'. The phone is back at rest before the hit at 1713. 1307 to 1713.

import { h, css, place } from '../engine/dom.js'
import { clamp, ease, lerp } from '../engine/anim.js'
import { captions, PHONE_AT } from '../engine/ui/split.js'
import { buildDesk, drawAgent, START, CAM_MID, TAP } from './herdr/common.js'

const DUR = START.h05 - START.h04
const BEAT = 50.704

// Local frames.
const F = {
  cap: 18, // 1325
  zoomEnd: 44, // the phone is large
  still: 133, // 1440: the break starts, the motion holds
  pulse: 253, // 1560: the pulse on '1 Yes'
  back: 348, // 1655: the phone scales back
  rest: 392, // 1699: at rest
}

// The large phone: 1.5 times the rest size, with capture y 40 at the top of
// the frame, so the dialog and the 3 choices show.
const BIG = { s: PHONE_AT.s * 1.5 }
BIG.x = 1150
BIG.y = -(30 + 40) * BIG.s

export default {
  id: 'h04-read',
  duration: DUR,

  mount(layer) {
    const d = buildDesk(layer)
    const b = TAP.yes.box
    const pulse = h('div', {
      style: {
        position: 'absolute', left: b.x - 3, top: b.y - 3, width: b.w + 6, height: b.h + 6, borderRadius: 26,
        border: '5px solid #7aa2f7', boxShadow: '0 0 40px 4px rgba(122,162,247,0.55)', boxSizing: 'border-box', visibility: 'hidden',
      },
    })
    d.s.phone.overlay.append(pulse)
    const c = captions(layer, {
      kicker: 'Output',
      title: 'Read the output in color.',
      sub: 'The phone shows the same dialog as the terminal.',
    })
    return { ...d, pulse, c }
  },

  update(r, f) {
    const g = START.h04 + f
    r.s.camKeys([{ f: 0, ...CAM_MID, z: CAM_MID.z * 1.03 }, { f: DUR, ...CAM_MID, z: CAM_MID.z * 1.05 }], f)
    drawAgent(r.term, g)
    r.s.phone.show({ codex: 1 })

    // The phone grows, drifts a little until the break, then holds.
    const inP = ease.camera(clamp(f / F.zoomEnd))
    const drift = ease.outCubic(clamp((f - F.zoomEnd) / (F.still - F.zoomEnd)))
    const outP = ease.inOutCubic(clamp((f - F.back) / (F.rest - F.back)))
    const big = { s: BIG.s * (1 + 0.012 * drift), x: BIG.x - 6 * drift, y: BIG.y - 4 * drift }
    const k = inP * (1 - outP)
    place(r.s.phone.el, { x: lerp(PHONE_AT.x, big.x, k), y: lerp(PHONE_AT.y, big.y, k), s: lerp(PHONE_AT.s, big.s, k) })

    // The desktop dims to 40 percent under the large phone.
    const dim = lerp(1, 0.4, k)
    r.s.pane.style.filter = dim < 0.999 ? `brightness(${dim.toFixed(4)})` : 'none'

    // The pulse on '1 Yes', on the beat of the music, until the phone scales back.
    const env = Math.min(ease.outCubic(clamp((f - F.pulse) / 20)), 1 - ease.inCubic(clamp((f - F.back) / 24)))
    const beat = 0.55 + 0.45 * Math.cos((2 * Math.PI * (f - F.pulse)) / BEAT)
    place(r.pulse, { o: f >= F.pulse ? env * beat : 0 })

    r.c.update(f, F.cap, DUR)
  },
}
