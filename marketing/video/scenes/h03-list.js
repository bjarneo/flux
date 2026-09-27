// h03-list: the agents list on the phone, blocked agents first. The
// billing card glows once, the camera eases back so the agent and the list
// read as one system, and a tap opens the codex output. 902 to 1307.

import { h, place } from '../engine/dom.js'
import { clamp, ease } from '../engine/anim.js'
import { captions } from '../engine/ui/split.js'
import { buildDesk, drawAgent, START, CAM_DIALOG, CAM_MID, TAP } from './herdr/common.js'

const DUR = START.h04 - START.h03

// Local frames.
const F = {
  cap: 18, // 920, also the red glow
  tap: 348, // 1250: a tap on the billing card
  open: 360, // 1262: the codex output
}

export default {
  id: 'h03-list',
  duration: DUR,

  mount(layer) {
    const d = buildDesk(layer)
    // A red glow around the billing card, in capture px.
    const b = TAP.billing.box
    const glow = h('div', {
      style: {
        position: 'absolute', left: b.x - 4, top: b.y - 4, width: b.w + 8, height: b.h + 8, borderRadius: 34,
        border: '5px solid #f7768e', boxShadow: '0 0 46px 6px rgba(247,118,142,0.55)', boxSizing: 'border-box', visibility: 'hidden',
      },
    })
    d.s.phone.overlay.append(glow)
    const c = captions(layer, {
      kicker: 'Agents',
      title: 'See every agent in one list.',
      sub: 'Blocked agents come first, then done, working, and idle agents.',
    })
    return { ...d, glow, c }
  },

  update(r, f) {
    const g = START.h03 + f
    r.s.camKeys([{ f: 0, ...CAM_DIALOG, z: CAM_DIALOG.z * 1.04 }, { f: 130, ...CAM_MID }, { f: DUR, ...CAM_MID, z: CAM_MID.z * 1.03 }], f)
    drawAgent(r.term, g)

    r.s.phone.show(f < F.open ? { agents: 1 } : { codex: 1 })
    r.s.phone.tap(TAP.billing.x, TAP.billing.y, f, F.tap)

    // The glow rises over 14 frames, holds, and fades by frame 90.
    const on = Math.min(ease.outCubic(clamp((f - F.cap) / 14)), 1 - ease.inCubic(clamp((f - 60) / 30)))
    place(r.glow, { o: f >= F.cap ? on : 0 })

    r.c.update(f, F.cap, DUR)
  },
}
