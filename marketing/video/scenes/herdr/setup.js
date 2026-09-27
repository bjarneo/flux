// The desktop of h06-setup, which h07-end also uses under the end card:
// the codex agent in the left tile, and a new shell in the right tile that
// turns on replies. setupAt(r, f) draws the state at local frame f of h06.

import { place } from '../../engine/dom.js'
import { typed } from '../../engine/anim.js'
import { popin, prompt } from '../../engine/ui/windows.js'
import { buildDesk, agentOutput, phoneOutput, START } from './common.js'

export const CMD1 = "echo 'herdr_control = true' >> ~/.config/flux/config.toml"
export const CMD2 = 'systemctl --user reload fluxd'

// Local frames of h06.
export const S = {
  pop: 0, // the shell window opens
  type1: 30, // 30 characters per second
  enter1: 156,
  type2: 170,
  enter2: 240,
  prompt3: 246,
}

/** The columns of the left tile: 700 px minus the padding, 9.6 px per cell. */
const COLS = 68

/** Wraps lines longer than COLS at a space, as the terminal does. */
function wrap(lines) {
  const out = []
  for (const segs of lines) {
    const text = segs.map((s) => s.t).join('')
    if (text.length <= COLS) { out.push(segs); continue }
    const cut = text.lastIndexOf(' ', COLS)
    // Split the segments at the cut, and drop the space at the cut.
    const a = [], b = []
    let pos = 0
    for (const s of segs) {
      const end = pos + s.t.length
      if (end <= cut) a.push(s)
      else if (pos >= cut + 1) b.push(s)
      else {
        if (cut > pos) a.push({ ...s, t: s.t.slice(0, cut - pos) })
        b.push({ ...s, t: s.t.slice(cut + 1 - pos) })
      }
      pos = end
    }
    out.push(a, [{ t: '  ' }, ...b])
  }
  return out
}

export function buildSetup(layer) {
  const d = buildDesk(layer, { layout: 'split' })
  const out = phoneOutput(d.s.phone.overlay)
  return { ...d, out }
}

/** Draws the setup desktop and the phone at local frame f of h06. */
export function setupAt(r, f) {
  const g = START.h06 + f
  const { lines } = agentOutput(g)
  // The codex tile is not focused: Ghostty draws no block cursor there.
  r.term.render(wrap(lines), null)

  const t1 = typed(CMD1, f, S.type1, 30)
  const t2 = typed(CMD2, f, S.type2, 30)
  const rows = [[], [...prompt('home'), { t: t1 }]]
  let cur = { line: 1, col: 4 + t1.length }
  if (f >= S.enter1) {
    rows.push([...prompt('home'), { t: t2 }])
    cur = { line: 2, col: 4 + t2.length }
  }
  if (f >= S.prompt3) {
    rows.push(prompt('home'))
    cur = { line: 3, col: 4 }
  }
  cur.on = f < S.type1 || f >= S.prompt3 ? Math.floor(f / 30) % 2 === 0 : true
  r.shell.term.render(rows, cur)

  const p = popin(f, S.pop)
  place(r.shell.win.el, { s: p.s, o: p.o })

  r.s.phone.show({ done: 1 })
  r.out.set(1, 1)
}
