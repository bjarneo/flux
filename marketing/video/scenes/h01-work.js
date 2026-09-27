// h01-work: the codex agent works in Ghostty and stops at an approval
// dialog. The phone shows the Flux device page. 0 to 496, downbeats at 91
// and 293.

import { captions } from '../engine/ui/split.js'
import { buildDesk, drawAgent, START, CAM_DIALOG } from './herdr/common.js'

const DUR = START.h02 - START.h01

export default {
  id: 'h01-work',
  duration: DUR,

  mount(layer) {
    const d = buildDesk(layer)
    const c = captions(layer, {
      kicker: 'herdr agents',
      title: 'Your coding agents work in herdr.',
      sub: 'Flux shows them on your phone.',
    })
    return { ...d, c }
  },

  update(r, f) {
    const g = START.h01 + f
    // The camera: close to the full desktop, then a push to the dialog
    // while the agent prints, landing as the dialog draws.
    r.s.camKeys([
      { f: 0, shot: 'WIDE' },
      { f: 60, shot: 'WIDE' },
      { f: 400, ...CAM_DIALOG },
    ], f)
    r.s.phone.show({ nobadge: 1 })
    drawAgent(r.term, g)
    r.c.update(f, 91, DUR, 130)
  },
}
