// t03-leave: The phone leaves the Wi-Fi. The old link drops in the break of the music.
// The shared desk in scenes/tailscale/desk.js draws everything from the
// global frame, so the cuts to the next scene match.

import { captions } from '../engine/ui/split.js'
import { buildDesk, deskAt, T } from './tailscale/desk.js'

const START = T.t03
const D = T.t04 - T.t03

export default {
  id: 't03-leave',
  duration: D,

  mount(layer) {
    const r = buildDesk(layer)
    r.c = captions(layer, {
      kicker: 'Away',
      title: 'Your phone leaves the Wi-Fi.',
      sub: 'fluxd sees that the old link is down.',
    })
    return r
  },

  update(r, f) {
    deskAt(r, START + f)
    r.c.update(f, 18, D, 366)
  },
}
