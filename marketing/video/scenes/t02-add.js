// t02-add: Add the Tailscale name of the phone, then check it with flux doctor.
// The shared desk in scenes/tailscale/desk.js draws everything from the
// global frame, so the cuts to the next scene match.

import { captions } from '../engine/ui/split.js'
import { buildDesk, deskAt, T } from './tailscale/desk.js'

const START = T.t02
const D = T.t03 - T.t02

export default {
  id: 't02-add',
  duration: D,

  mount(layer) {
    const r = buildDesk(layer)
    r.c = captions(layer, {
      kicker: 'Setup',
      title: 'Add the Tailscale name of your phone.',
      sub: 'Pair on your local network first. Then add the name once.',
    })
    return r
  },

  update(r, f) {
    deskAt(r, START + f)
    r.c.update(f, 18, D)
  },
}
