// h02-ping: the agent waits at the dialog. The phone vibrates and shows the
// Flux heads-up 'codex in billing needs input', the Agents tile gets its
// count, and a tap on the tile opens the agents list. 496 to 902.

import { captions, arc } from '../engine/ui/split.js'
import { headsUp } from '../engine/ui/headsup.js'
import { buildDesk, drawAgent, cell, START, CAM_DIALOG, TAP, LINE } from './herdr/common.js'

const DUR = START.h03 - START.h02

// Local frames.
const F = {
  ping: 4, // 500: vibrate, heads-up, count on the tile
  huOut: 144, // 640: the heads-up slides up
  cap: 18, // 514
  tap: 304, // 800: a tap on the Agents tile
  list: 316, // 812: the agents list
}

export default {
  id: 'h02-ping',
  duration: DUR,

  mount(layer) {
    const d = buildDesk(layer)
    const hu = headsUp({ title: 'codex in billing needs input', text: 'Run the database migration' })
    d.s.phone.overlay.append(hu.el)
    const c = captions(layer, {
      kicker: 'Notifications',
      title: 'Know when an agent needs you.',
      sub: 'The phone gets a notification when an agent waits for input.',
      dir: 'omarchy-xps → Pixel 8',
    })
    const a = arc(d.s.overlay)
    return { ...d, hu, c, a }
  },

  update(r, f) {
    const g = START.h02 + f
    // The camera holds on the dialog with a slow drift.
    r.s.camKeys([{ f: 0, ...CAM_DIALOG }, { f: DUR, ...CAM_DIALOG, z: CAM_DIALOG.z * 1.04 }], f)
    drawAgent(r.term, g)

    r.s.vibrate(f, F.ping, 60)
    const screen = f < F.ping ? 'nobadge' : f < F.list ? 'home' : 'agents'
    r.s.phone.show({ [screen]: 1 })
    r.hu.update(f, F.ping, F.huOut)
    r.s.phone.tap(TAP.agentsTile.x, TAP.agentsTile.y, f, F.tap)

    // The flux arc from the right end of the dialog rule to the heads-up,
    // over the empty part of the window, so it does not cross the text.
    const rule = cell(LINE.dialog, 73)
    r.a.draw(f, F.ping, r.s.deskToFrame(rule.x, rule.y), r.s.phoneToFrame(TAP.headsUp.x, TAP.headsUp.y))

    r.c.update(f, F.cap, DUR)
  },
}
