// h07-end: the end card, adapted from the earlier video (ref/s17-end.js).
// The last frame of h06-setup dims and blurs, and the Flux lockup, the
// tagline, and the install lines for both sides build over it. It ends on
// black as the music fades out. 2727 to 3133.

import { h, css, place } from '../engine/dom.js'
import { clamp, ease, typed } from '../engine/anim.js'
import { C, FONT } from '../engine/tokens.js'
import { fluxMark } from '../engine/ui/bits.js'
import { reveal } from '../engine/ui/text.js'
import { START } from './herdr/common.js'
import { buildSetup, setupAt } from './herdr/setup.js'

const D = START.end - START.h07
const H06 = START.h07 - START.h06

const F = {
  dim: 0, dimEnd: 36,
  mark: 24, markEnd: 78,
  word: 48,
  tag: 72,
  sub: 102,
  col2: 111,
  type1: 120,
  prompt2: 164,
  type2: 168,
  android: 174,
  black: 368, // fade to black over the last 0.6 s
}

const CMD1 = 'yay -S omarchy-flux'
const CMD2 = 'flux setup'
const APK = 'Get the APK from the Flux GitHub release.'
const DY = 44
const LX = -10
const ink = C.ink
const inkDim = C.inkDim

function rise(el, f, start, dy = 16, n = 24) {
  const p = ease.outCubic(clamp((f - start) / n))
  place(el, { y: dy * (1 - p), o: p })
}

export default {
  id: 'h07-end',
  duration: D,

  mount(layer) {
    const wrap = h('div', { style: { position: 'absolute', inset: 0, background: C.bgDarker } })
    layer.append(wrap)
    const bg = buildSetup(wrap)
    css(bg.s.root, { transformOrigin: '960px 540px' })

    const card = h('div', { style: { position: 'absolute', inset: 0, pointerEvents: 'none' } })
    layer.append(card)

    const mark = fluxMark(120, { fg: C.fgBright, accent: C.accent })
    css(mark.el, { left: 766 + LX, top: 214 + DY })
    const word = h('svg', { width: 1920, height: 1080, viewBox: '0 0 1920 1080', style: 'position:absolute;left:0;top:0;overflow:visible' },
      h('text', { x: 914 + LX, y: 306 + DY, fill: C.fgBright, 'font-family': "'JetBrainsMono Nerd Font', 'JetBrains Mono', monospace", 'font-weight': 700, 'font-size': 100 }, 'flux'))
    card.append(h('div', { style: { position: 'absolute', inset: 0 } }, mark.el, word))

    const tag = reveal('herdr agents on your phone.', {
      left: 0, top: 372 + DY, width: 1920, textAlign: 'center', fontSize: 46, fontWeight: 600, color: ink, letterSpacing: '-0.02em', lineHeight: '1.1',
    }, { stagger: 3, dur: 34 })
    const sub = h('div', {
      style: { position: 'absolute', left: 0, top: 446 + DY, width: 1920, textAlign: 'center', fontFamily: FONT.sans, fontSize: 24, fontWeight: 500, color: inkDim, lineHeight: '32px', visibility: 'hidden' },
      text: 'Install Flux on both sides.',
    })
    card.append(tag.el, sub)

    const label = (text, x) => h('div', {
      style: { position: 'absolute', left: x, top: 512 + DY, fontFamily: FONT.mono, fontWeight: 700, fontSize: 16, lineHeight: '20px', letterSpacing: '0.14em', color: C.accent, visibility: 'hidden' },
      text,
    })
    const labelL = label('ON OMARCHY', 330)
    const labelR = label('ON ANDROID', 990)

    const mono = { fontFamily: FONT.mono, fontSize: 28, lineHeight: '40px', whiteSpace: 'pre', color: C.fgBright }
    const promptEl = () => h('span', { style: { color: C.cyan, fontWeight: 700 }, text: '~ ❯ ' })
    const cmd1 = h('span', { text: '' })
    const cmd2 = h('span', { text: '' })
    const cursorEl = h('span', { style: { display: 'inline-block', width: '0.6em', height: 32, verticalAlign: '-6px', background: C.fgBright } })
    const line1 = h('div', { style: mono }, promptEl(), cmd1)
    const prompt2 = promptEl()
    const line2 = h('div', { style: mono }, prompt2, cmd2)
    const cardL = h('div', {
      style: {
        position: 'absolute', left: 330, top: 548 + DY, width: 600, height: 150, boxSizing: 'border-box', background: C.bg, border: `2px solid ${C.accent}`,
        display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 10, paddingLeft: 34, visibility: 'hidden',
      },
    }, line1, line2)
    const apk = h('div', { style: { fontFamily: FONT.sans, fontWeight: 500, fontSize: 26, lineHeight: '40px', color: C.fg, whiteSpace: 'nowrap' }, text: APK })
    const cardR = h('div', {
      style: {
        position: 'absolute', left: 990, top: 548 + DY, width: 600, height: 150, boxSizing: 'border-box', background: C.bg2, border: `1px solid ${C.bg3}`,
        display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 10, paddingLeft: 34, visibility: 'hidden',
      },
    }, apk)
    card.append(labelL, labelR, cardL, cardR)

    const black = h('div', { style: { position: 'absolute', inset: 0, background: '#000', visibility: 'hidden' } })
    layer.append(black)

    return { wrap, bg, mark, word, tag, sub, labelL, labelR, cardL, cardR, cmd1, cmd2, prompt2, cursorEl, line1, line2, apk, black }
  },

  update(r, f) {
    // The setup desktop holds on the last frame of h06, with its camera.
    r.bg.s.cam(1.6, 1000, 280)
    setupAt(r.bg, H06 - 1)
    const p = ease.outCubic(clamp((f - F.dim) / (F.dimEnd - F.dim)))
    r.wrap.style.filter = p > 0 ? `brightness(${(1 - 0.7 * p).toFixed(4)})` : 'none'
    r.bg.s.root.style.filter = p > 0 ? `blur(${(8 * p).toFixed(3)}px)` : 'none'
    r.bg.s.root.style.transform = p > 0 ? `scale(${(1 - 0.04 * p).toFixed(5)})` : 'none'

    r.mark.draw(clamp((f - F.mark) / (F.markEnd - F.mark)))
    r.mark.el.style.visibility = f >= F.mark ? 'visible' : 'hidden'
    rise(r.word, f, F.word, 12, 24)

    r.tag.update(f, F.tag)
    rise(r.sub, f, F.sub, 10, 24)
    rise(r.labelL, f, F.sub)
    rise(r.cardL, f, F.sub)
    rise(r.labelR, f, F.col2)
    rise(r.cardR, f, F.col2)

    const t1 = typed(CMD1, f, F.type1, 30)
    const t2 = typed(CMD2, f, F.type2, 30)
    if (r.cmd1.textContent !== t1) r.cmd1.textContent = t1
    if (r.cmd2.textContent !== t2) r.cmd2.textContent = t2
    const onLine2 = f >= F.prompt2
    r.prompt2.style.visibility = onLine2 ? 'visible' : 'hidden'
    const host = onLine2 ? r.line2 : r.line1
    if (r.cursorEl.parentNode !== host) host.append(r.cursorEl)

    rise(r.apk, f, F.android, 8, 20)

    const b = ease.inOutCubic(clamp((f - F.black) / (D - 1 - F.black)))
    r.black.style.opacity = String(b)
    r.black.style.visibility = b > 0.001 ? 'visible' : 'hidden'
  },
}
