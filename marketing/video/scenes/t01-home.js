// t01-home: Flux at home on Wi-Fi: the bar shows the phone as connected.
// The shared desk in scenes/tailscale/desk.js draws everything from the
// global frame, so the cuts to the next scene match.

import { captions } from '../engine/ui/split.js'
import { buildDesk, deskAt, T } from './tailscale/desk.js'

const START = T.t01
const D = T.t02 - T.t01

export default {
  id: 't01-home',
  duration: D,

  mount(layer) {
    const r = buildDesk(layer)
    r.c = captions(layer, {
      kicker: 'Tailscale',
      title: 'Use Flux away from home.',
      sub: 'Flux reaches your phone through Tailscale.',
    })
    return r
  },

  update(r, f) {
    deskAt(r, START + f)
    r.c.update(f, 18, D, 60)
  },
}
