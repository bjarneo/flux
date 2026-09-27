// Camera images made in SVG. No stock footage exists, so the webcam shows a
// lit person silhouette in a room, and the text scan shows a paper page.

import { h, css } from '../dom.js'
import { FPS } from '../anim.js'

let uid = 0

/**
 * A webcam image of w x h px: a warm room, soft background lights, and a
 * person with rim light. mirror flips it. update(f) adds a slow breath and
 * a small head move.
 */
export function webcamFeed(w, hh, { mirror = false } = {}) {
  const id = `wf${uid++}`
  const vb = 1600, vh = 900
  const svg = h('svg', {
    width: w, height: hh, viewBox: `0 0 ${vb} ${vh}`, preserveAspectRatio: 'xMidYMid slice',
    style: `position:absolute;left:0;top:0;display:block;${mirror ? 'transform:scaleX(-1)' : ''}`,
  })
  const defs = h('defs', {},
    h('linearGradient', { id: `${id}-room`, x1: 0, y1: 0, x2: 1, y2: 1 },
      h('stop', { offset: '0', 'stop-color': '#3a2d3f' }),
      h('stop', { offset: '0.55', 'stop-color': '#231d2c' }),
      h('stop', { offset: '1', 'stop-color': '#15131c' })),
    h('radialGradient', { id: `${id}-win`, cx: 0.5, cy: 0.5, r: 0.5 },
      h('stop', { offset: '0', 'stop-color': '#ffd9a8', 'stop-opacity': '0.85' }),
      h('stop', { offset: '1', 'stop-color': '#ffb070', 'stop-opacity': '0' })),
    h('radialGradient', { id: `${id}-key`, cx: 0.72, cy: 0.35, r: 0.6 },
      h('stop', { offset: '0', 'stop-color': '#ffcf9a', 'stop-opacity': '0.28' }),
      h('stop', { offset: '1', 'stop-color': '#ffcf9a', 'stop-opacity': '0' })),
    h('linearGradient', { id: `${id}-body`, x1: 0, y1: 0, x2: 1, y2: 0 },
      h('stop', { offset: '0', 'stop-color': '#1d1822' }),
      h('stop', { offset: '0.7', 'stop-color': '#2a2230' }),
      h('stop', { offset: '1', 'stop-color': '#4a3438' })),
    h('radialGradient', { id: `${id}-face`, cx: 0.62, cy: 0.42, r: 0.65 },
      h('stop', { offset: '0', 'stop-color': '#7a5a55' }),
      h('stop', { offset: '0.6', 'stop-color': '#3c2d33' }),
      h('stop', { offset: '1', 'stop-color': '#1e1920' })),
    h('radialGradient', { id: `${id}-vig`, cx: 0.5, cy: 0.5, r: 0.75 },
      h('stop', { offset: '0.55', 'stop-color': '#000', 'stop-opacity': '0' }),
      h('stop', { offset: '1', 'stop-color': '#000', 'stop-opacity': '0.55' })),
    h('filter', { id: `${id}-blur40`, x: '-50%', y: '-50%', width: '200%', height: '200%' }, h('feGaussianBlur', { stdDeviation: 40 })),
    h('filter', { id: `${id}-blur14`, x: '-50%', y: '-50%', width: '200%', height: '200%' }, h('feGaussianBlur', { stdDeviation: 14 })),
    h('filter', { id: `${id}-blur6`, x: '-50%', y: '-50%', width: '200%', height: '200%' }, h('feGaussianBlur', { stdDeviation: 6 })),
  )
  svg.append(defs)
  svg.append(h('rect', { x: 0, y: 0, width: vb, height: vh, fill: `url(#${id}-room)` }))
  // A window glow at the right and a warm key light.
  svg.append(h('rect', { x: 1080, y: 70, width: 420, height: 520, rx: 30, fill: `url(#${id}-win)`, filter: `url(#${id}-blur40)` }))
  svg.append(h('rect', { x: 0, y: 0, width: vb, height: vh, fill: `url(#${id}-key)` }))
  // Shelf and plant shapes, out of focus.
  const bg = h('g', { filter: `url(#${id}-blur14)`, opacity: 0.9 })
  bg.append(
    h('rect', { x: 120, y: 250, width: 420, height: 16, fill: '#4a3a44' }),
    h('rect', { x: 150, y: 170, width: 38, height: 80, fill: '#6f5a8a' }),
    h('rect', { x: 196, y: 150, width: 30, height: 100, fill: '#8a6f55' }),
    h('rect', { x: 232, y: 185, width: 44, height: 65, fill: '#4f6f8a' }),
    h('rect', { x: 330, y: 200, width: 90, height: 50, rx: 8, fill: '#5d4a3f' }),
    h('ellipse', { cx: 1320, cy: 640, rx: 110, ry: 190, fill: '#2f4a3a' }),
    h('ellipse', { cx: 1250, cy: 560, rx: 70, ry: 120, fill: '#3b5a44' }),
  )
  svg.append(bg)
  // Bokeh lights.
  const bokeh = [[260, 120, 26, '#ffcf8a'], [420, 90, 18, '#ffe0b0'], [560, 140, 22, '#f5b27a'], [1180, 150, 30, '#ffd49a'], [980, 110, 16, '#a9c0ff'], [80, 420, 20, '#ffcf8a']]
  const bk = h('g', { filter: `url(#${id}-blur6)` })
  for (const [x, y, r, c] of bokeh) bk.append(h('circle', { cx: x, cy: y, r, fill: c, opacity: 0.55 }))
  svg.append(bk)
  // The person: shoulders, neck, head, with rim light on the right.
  const person = h('g', {})
  const shoulders = h('path', { d: 'M470 900 C 500 700, 610 640, 800 630 C 990 640, 1100 700, 1130 900 Z', fill: `url(#${id}-body)` })
  const neck = h('path', { d: 'M745 560 L 745 650 C 770 668, 830 668, 855 650 L 855 560 Z', fill: '#2c2229' })
  const head = h('ellipse', { cx: 800, cy: 450, rx: 118, ry: 146, fill: `url(#${id}-face)` })
  const hair = h('path', { d: 'M682 430 C 670 300, 760 270, 815 280 C 900 285, 935 350, 920 440 C 900 380, 850 350, 790 352 C 730 355, 700 390, 682 430 Z', fill: '#17131a' })
  const rim = h('path', { d: 'M905 380 C 935 440, 925 540, 868 590', stroke: '#ffcf9a', 'stroke-width': 7, fill: 'none', opacity: 0.55, filter: `url(#${id}-blur6)` })
  const rimShoulder = h('path', { d: 'M960 660 C 1050 690, 1100 760, 1120 900', stroke: '#ffcf9a', 'stroke-width': 9, fill: 'none', opacity: 0.35, filter: `url(#${id}-blur6)` })
  person.append(shoulders, neck, head, hair, rim, rimShoulder)
  svg.append(person)
  // Vignette and a fixed grain.
  svg.append(h('rect', { x: 0, y: 0, width: vb, height: vh, fill: `url(#${id}-vig)` }))
  const grainF = h('filter', { id: `${id}-grain` },
    h('feTurbulence', { type: 'fractalNoise', baseFrequency: 0.9, numOctaves: 2, seed: 7 }),
    h('feColorMatrix', { type: 'saturate', values: 0 }))
  defs.append(grainF)
  svg.append(h('rect', { x: 0, y: 0, width: vb, height: vh, filter: `url(#${id}-grain)`, opacity: 0.06 }))

  const el = h('div', { style: { position: 'absolute', left: 0, top: 0, width: w, height: hh, overflow: 'hidden', background: '#15131c' } }, svg)
  return {
    el,
    update(f) {
      const t = f / FPS
      const breath = Math.sin(t * 1.6) * 0.006
      const nod = Math.sin(t * 0.9) * 1.6
      person.setAttribute('transform', `translate(800 900) scale(${1 + breath}) translate(-800 -900) rotate(${nod * 0.4} 800 640)`)
      head.setAttribute('transform', `rotate(${nod} 800 560)`)
      hair.setAttribute('transform', `rotate(${nod} 800 560)`)
    },
  }
}

/**
 * A paper page on a dark desk, for the text scan. lines are the printed
 * text. highlight(p) draws the recognition boxes from 0 to 1.
 */
export function paperFeed(w, hh, lines = []) {
  const el = h('div', {
    style: {
      position: 'absolute', left: 0, top: 0, width: w, height: hh, overflow: 'hidden',
      background: 'radial-gradient(ellipse at 50% 40%, #3a3440 0%, #1c1a22 70%)',
    },
  })
  const page = h('div', {
    style: {
      position: 'absolute', left: '12%', top: '10%', width: '76%', height: '84%', background: '#f1ede4',
      transform: 'perspective(1400px) rotateX(8deg) rotateZ(-2.5deg)', boxShadow: '0 30px 60px rgba(0,0,0,0.5)',
      padding: `${hh * 0.07}px ${w * 0.07}px`, fontFamily: "'Liberation Serif', Georgia, serif", color: '#262320',
    },
  })
  const boxes = []
  lines.forEach((t, i) => {
    const row = h('div', { style: { position: 'relative', fontSize: i === 0 ? hh * 0.045 : hh * 0.028, fontWeight: i === 0 ? '700' : '400', lineHeight: '1.5', marginBottom: i === 0 ? hh * 0.02 : 0 } })
    const span = h('span', { style: { position: 'relative' }, text: t })
    const box = h('span', { style: { position: 'absolute', left: -6, right: -6, top: -2, bottom: -2, border: '3px solid #7aa2f7', background: 'rgba(122,162,247,0.12)', opacity: '0' } })
    span.append(box)
    row.append(span)
    page.append(row)
    boxes.push(box)
  })
  el.append(page)
  return {
    el,
    highlight(p) {
      boxes.forEach((b, i) => {
        const q = Math.min(1, Math.max(0, p * boxes.length - i))
        b.style.opacity = String(q)
      })
    },
  }
}
