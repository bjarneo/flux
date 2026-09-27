// t04-back: On the hit, the link comes back through Tailscale, and a notification arrives.
// The shared desk in scenes/tailscale/desk.js draws everything from the
// global frame, so the cuts to the next scene match.

import { captions } from '../engine/ui/split.js'
import { buildDesk, deskAt, T } from './tailscale/desk.js'

const START = T.t04
const D = T.t05 - T.t04

export default {
  id: 't04-back',
  duration: D,

  mount(layer) {
    const r = buildDesk(layer)
    r.c = captions(layer, {
      kicker: 'Tailscale',
      title: 'Flux connects again through Tailscale.',
      sub: 'fluxd dials the extra address while the phone is offline.',
    })
    return r
  },

  update(r, f) {
    deskAt(r, START + f)
    r.c.update(f, 12, D)
  },
}
