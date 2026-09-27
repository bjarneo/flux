// h06-setup: a new Ghostty tile turns on replies with one line in the
// Flux config and a reload of fluxd. The codex agent waits in the left
// tile, and the phone shows it as done. 2322 to 2727.

import { captions } from '../engine/ui/split.js'
import { START } from './herdr/common.js'
import { buildSetup, setupAt } from './herdr/setup.js'

const DUR = START.h07 - START.h06

export default {
  id: 'h06-setup',
  duration: DUR,

  mount(layer) {
    const d = buildSetup(layer)
    const c = captions(layer, {
      kicker: 'Setup',
      title: 'Turn on replies with one line.',
      sub: 'Replies are off by default, because an agent can run commands.',
    })
    return { ...d, c }
  },

  update(r, f) {
    // From the full desktop to the new shell tile, as the command types.
    r.s.camKeys([{ f: 0, shot: 'WIDE' }, { f: 8, shot: 'WIDE' }, { f: 70, z: 1.55, cx: 1000, cy: 280 }, { f: DUR, z: 1.6, cx: 1000, cy: 280 }], f)
    setupAt(r, f)
    r.c.update(f, 18, DUR)
  },
}
