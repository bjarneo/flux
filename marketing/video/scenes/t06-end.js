// t06-end: the end card of the Tailscale video. It dims and blurs the desk
// of t05, builds the Flux lockup, the title, the command that adds the
// Tailscale name, and the docs line. It ends on black. The layout follows
// the end card of the earlier Flux video, ref/s17-end.js.

import { h, css, place } from '../engine/dom.js'
import { clamp, ease } from '../engine/anim.js'
import { C, FONT } from '../engine/tokens.js'
import { fluxMark } from '../engine/ui/bits.js'
import { reveal } from '../engine/ui/text.js'
import { buildDesk, deskAt, T } from './tailscale/desk.js'

const START = T.t06
const D = T.end - T.t06

// Beats in local frames.
const F = {
  dim: 0, dimEnd: 36,        // the desk dims, blurs, and scales down
  mark: 24, markEnd: 78,     // the mark draws
  word: 48,                  // the wordmark rises in
  tag: 72,                   // the title
  sub: 102,                  // the sub line
  box: 118,                  // the command box
  type: 132,                 // the command types at 34 cps
  docs: 236,                 // the docs line
  black: 330,                // fade to black, black on the last frame
}

const CMD_A = 'flux --device "Pixel 8" addresses add '
const CMD_B = 'pixel-8'
const CPS = 34

// The storyboard layout of s17 moves down by DY and the lockup by LX.
const DY = 44
const LX = -10
const ink = '#e6e9f5'
const inkDim = '#8b91b4'

// The box fits the prompt and the command: JetBrains Mono advances 0.6 em.
const MONO = 28
const CHARS = 4 + CMD_A.length + CMD_B.length
const BOX_W = Math.ceil(CHARS * MONO * 0.6 + 2 * 34 + MONO * 0.6)
const BOX = { x: Math.round(960 - BOX_W / 2), y: 526 + DY, w: BOX_W, h: 96 }

/** Fade in and rise by dy px over n frames from frame start. */
function rise(el, f, start, dy = 16, n = 24) {
  const p = ease.outCubic(clamp((f - start) / n))
  place(el, { y: dy * (1 - p), o: p })
}

export default {
  id: 't06-end',
  duration: D,

  mount(layer) {
    const r = buildDesk(layer)
    css(r.s.root, { transformOrigin: '960px 540px' })

    const card = h('div', { style: { position: 'absolute', inset: 0, pointerEvents: 'none' } })
    layer.append(card)

    const mark = fluxMark(120, { fg: C.fgBright, accent: C.accent })
    css(mark.el, { left: 766 + LX, top: 214 + DY })
    const word = h('svg', { width: 1920, height: 1080, viewBox: '0 0 1920 1080', style: 'position:absolute;left:0;top:0;overflow:visible' },
      h('text', { x: 914 + LX, y: 306 + DY, fill: C.fgBright, 'font-family': "'JetBrainsMono Nerd Font', 'JetBrains Mono', monospace", 'font-weight': 700, 'font-size': 100 }, 'flux'))
    card.append(mark.el, word)

    const tag = reveal('Flux through Tailscale.', {
      left: 0, top: 372 + DY, width: 1920, textAlign: 'center', fontSize: 46, fontWeight: 600, color: ink, letterSpacing: '-0.02em', lineHeight: '1.1',
    }, { stagger: 3, dur: 34 })
    const sub = h('div', {
      style: { position: 'absolute', left: 0, top: 446 + DY, width: 1920, textAlign: 'center', fontFamily: FONT.sans, fontSize: 24, fontWeight: 500, color: inkDim, lineHeight: '32px', visibility: 'hidden' },
      text: 'Add the Tailscale name of your phone once.',
    })
    card.append(tag.el, sub)

    const mono = { fontFamily: FONT.mono, fontSize: MONO, lineHeight: '40px', whiteSpace: 'pre', color: C.fgBright }
    const cmdA = h('span', { text: '' })
    const cmdB = h('span', { style: { color: C.accent }, text: '' })
    const cur = h('span', { style: { display: 'inline-block', width: '0.6em', height: 32, verticalAlign: '-6px', background: C.fgBright } })
    const line = h('div', { style: mono }, h('span', { style: { color: C.cyan, fontWeight: 700 }, text: '~ ❯ ' }), cmdA, cmdB, cur)
    const box = h('div', {
      style: {
        position: 'absolute', left: BOX.x, top: BOX.y, width: BOX.w, height: BOX.h, boxSizing: 'border-box', background: C.bg,
        border: `2px solid ${C.accent}`, display: 'flex', alignItems: 'center', paddingLeft: 34, visibility: 'hidden',
      },
    }, line)
    const docs = h('div', {
      style: { position: 'absolute', left: 0, top: BOX.y + BOX.h + 30, width: 1920, textAlign: 'center', fontFamily: FONT.sans, fontSize: 24, fontWeight: 500, color: inkDim, lineHeight: '32px', visibility: 'hidden' },
      html: `Read <span style="font-family:${FONT.mono};font-size:23px;color:${C.accent}">docs/tailscale.md</span> for the steps.`,
    })
    card.append(box, docs)

    const black = h('div', { style: { position: 'absolute', inset: 0, background: '#000', visibility: 'hidden' } })
    layer.append(black)
    return { ...r, mark, word, tag, sub, box, cmdA, cmdB, docs, black }
  },

  update(r, f) {
    // The desk continues from t05 and goes to the back.
    deskAt(r, START + f)
    const p = ease.outCubic(clamp((f - F.dim) / (F.dimEnd - F.dim)))
    r.s.root.style.filter = p > 0 ? `brightness(${(1 - 0.72 * p).toFixed(4)}) blur(${(8 * p).toFixed(3)}px)` : 'none'
    r.s.root.style.transform = p > 0 ? `scale(${(1 - 0.04 * p).toFixed(5)})` : 'none'

    r.mark.draw(clamp((f - F.mark) / (F.markEnd - F.mark)))
    r.mark.el.style.visibility = f >= F.mark ? 'visible' : 'hidden'
    rise(r.word, f, F.word, 12, 24)
    r.tag.update(f, F.tag)
    rise(r.sub, f, F.sub, 10, 24)
    rise(r.box, f, F.box)

    const n = Math.max(0, Math.floor(((f - F.type) / 60) * CPS))
    const a = CMD_A.slice(0, Math.min(n, CMD_A.length))
    const b = CMD_B.slice(0, Math.max(0, n - CMD_A.length))
    if (r.cmdA.textContent !== a) r.cmdA.textContent = a
    if (r.cmdB.textContent !== b) r.cmdB.textContent = b
    rise(r.docs, f, F.docs, 8, 22)

    const k = ease.inOutCubic(clamp((f - F.black) / (D - 1 - F.black)))
    r.black.style.opacity = String(k)
    r.black.style.visibility = k > 0.001 ? 'visible' : 'hidden'
  },
}
