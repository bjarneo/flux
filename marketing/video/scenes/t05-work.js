// t05-work: Features work away from home: the agents list on 5G and flux status.
// The shared desk in scenes/tailscale/desk.js draws everything from the
// global frame, so the cuts to the next scene match.

import { captions } from '../engine/ui/split.js'
import { buildDesk, deskAt, T } from './tailscale/desk.js'

const START = T.t05
const D = T.t06 - T.t05

export default {
  id: 't05-work',
  duration: D,

  mount(layer) {
    const r = buildDesk(layer)
    r.c = captions(layer, {
      kicker: 'Everywhere',
      title: 'Every feature uses the same link.',
      sub: 'Files, clipboard, notifications, and agents work through Tailscale.',
    })
    return r
  },

  update(r, f) {
    deskAt(r, START + f)
    r.c.update(f, 18, D)
  },
}
