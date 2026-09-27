// h05-answer: on the hit of the music, a tap on '1 Yes' answers the dialog.
// The arc carries the answer to the terminal, the dialog closes, and the
// agent applies the migration. The phone shows the agent as working, and
// at 2119 the heads-up 'codex in billing finished' comes in. 1713 to 2322.

import { h, place } from '../engine/dom.js'
import { clamp, ease } from '../engine/anim.js'
import { captions, arc, rings } from '../engine/ui/split.js'
import { headsUp } from '../engine/ui/headsup.js'
import { buildDesk, drawAgent, phoneOutput, cell, START, CAM_DIALOG, TAP, LINE } from './herdr/common.js'

const DUR = START.h06 - START.h05

// Local frames.
const F = {
  tap: 0, // 1713, on the hit
  cap: 12, // 1725, the dialog closes
  working: 24, // the phone shows the agent as working, without the dialog
  lines: 160, // 1873: the phone reads the output again, with the new lines
  done: 406, // 2119: the finished heads-up, and the agent shows as done
  huOut: 547, // 2260
}

export default {
  id: 'h05-answer',
  duration: DUR,

  mount(layer) {
    const d = buildDesk(layer)
    // The pressed state of '1 Yes', in capture px.
    const b = TAP.yes.box
    const press = h('div', {
      style: {
        position: 'absolute', left: b.x, top: b.y, width: b.w, height: b.h, borderRadius: 22, background: 'rgba(178,197,255,0.16)',
        visibility: 'hidden',
      },
    })
    d.s.phone.overlay.append(press)
    const out = phoneOutput(d.s.phone.overlay)
    const hu = headsUp({ title: 'codex in billing finished', text: 'Run the database migration' })
    d.s.phone.overlay.append(hu.el)
    const c = captions(layer, {
      kicker: 'Replies',
      title: 'Answer from your phone.',
      sub: 'A tap sends the number of the choice to the agent.',
      dir: 'Pixel 8 → omarchy-xps',
    })
    const a = arc(d.s.overlay)
    const rg = rings(d.s.overlay)
    return { ...d, press, out, hu, c, a, rg }
  },

  update(r, f) {
    const g = START.h05 + f
    r.s.camKeys([{ f: 0, ...CAM_DIALOG }, { f: DUR, ...CAM_DIALOG, z: CAM_DIALOG.z * 1.05 }], f)
    drawAgent(r.term, g)

    // The screen changes to the working agent with a short crossfade, and
    // to the done agent with the finished heads-up.
    const w = ease.inOutCubic(clamp((f - F.working) / 8))
    const dn = f >= F.done ? 1 : 0
    r.s.phone.show({ codex: 1 - w, working: w * (1 - dn), done: dn })
    r.out.set(w, ease.outCubic(clamp((f - F.lines) / 12)))
    r.s.phone.tap(TAP.yes.x, TAP.yes.y, f, F.tap)
    place(r.press, { o: f < F.working ? Math.min(1, (f + 1) / 4) : 0 })
    r.s.vibrate(f, F.done, 30)
    r.hu.update(f, F.done, F.huOut)

    const yes = r.s.phoneToFrame(TAP.yes.x, TAP.yes.y)
    r.rg.draw(f, F.tap, 54, yes.x, yes.y)
    const rule = cell(LINE.dialog, 73)
    r.a.draw(f, F.tap + 2, yes, r.s.deskToFrame(rule.x, rule.y))

    r.c.update(f, F.cap, DUR)
  },
}
