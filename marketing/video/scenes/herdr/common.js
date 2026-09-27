// Shared parts of the herdr video: the desktop with the codex agent in
// Ghostty, the agent output at any frame of the video, the phone screens,
// and the frames of the storyboard. Every scene builds its own copy, and
// the output is a function of the global frame, so the cuts match.

import { h, css } from '../../engine/dom.js'
import { C } from '../../engine/tokens.js'
import { split } from '../../engine/ui/split.js'
import { hyprWindow, terminal, prompt, TERM } from '../../engine/ui/windows.js'

/** Scene starts in video frames. The video has 3133 frames. */
export const START = { h01: 0, h02: 496, h03: 902, h04: 1307, h05: 1713, h06: 2322, h07: 2727, end: 3133 }

/** The downbeats of Terminal Rain in video frames, from audio/music.json. */
export const DOWN = [91, 293, 496, 699, 902, 1105, 1307, 1510, 1713, 1916, 2119, 2322, 2524, 2727, 2930, 3133]

/** Phone screens, 1080 x 2400 capture px. */
export const SCREENS = {
  nobadge: 'assets/phone/home-nobadge.png',
  home: 'assets/phone/home.png',
  agents: 'assets/phone/agents.png',
  codex: 'assets/phone/agent-codex.png',
  working: 'scenes/herdr/agent-codex-working.png',
  done: 'scenes/herdr/agent-codex-done.png',
}

/** Tap targets and boxes in capture px. */
export const TAP = {
  agentsTile: { x: 946, y: 1455 },
  billing: { x: 540, y: 402, box: { x: 26, y: 276, w: 1028, h: 252 } },
  yes: { x: 540, y: 1749, box: { x: 28, y: 1704, w: 1024, h: 90 } },
  headsUp: { x: 540, y: 259 },
}

// Terminal colors of the Tokyo Night Ghostty theme for the ANSI codes of
// the sample output in DebugDemo.kt.
const RUST = 'rgb(215,119,87)'
const GREEN = '#9ece6a'
const BLUE = '#7aa2f7'
const CYAN = '#7dcfff'
const DIM = C.fgDark
const BRIGHT = C.fgBright

const PROMPT = [{ t: '> ', c: DIM }, { t: 'Run the database migration', c: BRIGHT }]
const ADDED = [{ t: '●', c: RUST }, { t: ' I added the migration in ' }, { t: 'db/migrate/0042_add_invoice_status.sql', b: true, c: BRIGHT }, { t: '.' }]
const DRY = [{ t: '●', c: GREEN }, { t: ' ' }, { t: 'Bash', b: true, c: BRIGHT }, { t: '(bin/migrate --dry-run)' }]
const DRY_OUT = [{ t: '  ' }, { t: '⎿', c: DIM }, { t: '  1 migration to apply: ' }, { t: '0042_add_invoice_status', c: CYAN }]
const DIALOG = [
  [{ t: '─'.repeat(72), c: BLUE }],
  [{ t: ' ' }, { t: 'Bash command', b: true, c: BLUE }],
  [],
  [{ t: '   bin/migrate --apply' }],
  [{ t: '   ' }, { t: 'Apply the pending migration', c: DIM }],
  [],
  [{ t: ' Do you want to proceed?' }],
  [{ t: ' ' }, { t: '❯ 1. Yes', c: BLUE }],
  [{ t: '   2. Yes, and do not ask again for bin/migrate commands' }],
  [{ t: '   3. No, and tell Codex what to do differently ' }, { t: '(esc)', c: DIM }],
]
const AFTER = [
  [{ t: '●', c: GREEN }, { t: ' ' }, { t: 'Bash', b: true, c: BRIGHT }, { t: '(bin/migrate --apply)' }],
  [{ t: '  ' }, { t: '⎿', c: DIM }, { t: '  Applied ' }, { t: '0042_add_invoice_status', c: CYAN }],
  [],
  [{ t: '●', c: RUST }, { t: ' The migration is applied. The invoices table has a status column now.' }],
]

/** When each part of the output prints, in video frames. */
export const OUT = {
  prompt: 0, added: 40, dry: 120, dryOut: 170,
  dialog: 330, // one dialog line every 3 frames
  close: 1732, // the answer closes the dialog as the arc lands
  after: [1747, 1795, 1795, 1860],
  ready: 2119, // the agent is done and waits for a new prompt
}

/** Line numbers in the terminal. Line 0 is empty. */
export const LINE = { prompt: 1, added: 3, dry: 5, dryOut: 6, dialog: 8, yes: 15, after: 8 }

/**
 * The codex terminal at video frame g: { lines, cursor }. The block cursor
 * blinks on the next line while the agent works, hides while the dialog
 * shows, and sits after '> ' when the agent waits for a prompt.
 */
export function agentOutput(g) {
  const lines = [[]]
  const at = (n, segs) => { while (lines.length < n) lines.push([]); lines[n] = segs }
  if (g >= OUT.prompt) at(LINE.prompt, PROMPT)
  if (g >= OUT.added) at(LINE.added, ADDED)
  if (g >= OUT.dry) at(LINE.dry, DRY)
  if (g >= OUT.dryOut) at(LINE.dryOut, DRY_OUT)
  const dialogShown = g >= OUT.dialog && g < OUT.close
  if (dialogShown) {
    const n = Math.min(DIALOG.length, Math.floor((g - OUT.dialog) / 3) + 1)
    for (let i = 0; i < n; i++) at(LINE.dialog + i, DIALOG[i])
  }
  if (g >= OUT.close) {
    AFTER.forEach((segs, i) => { if (g >= OUT.after[i]) at(LINE.after + i, segs) })
  }
  let cursor = null
  const on = Math.floor(g / 30) % 2 === 0
  if (g >= OUT.ready) {
    at(lines.length + 1, [{ t: '> ', c: DIM }])
    cursor = { line: lines.length - 1, col: 2, on }
  } else if (g >= OUT.prompt && !dialogShown && !(g >= OUT.close && g < OUT.after[0])) {
    const next = lines.length + 1
    at(next, [])
    cursor = { line: next, col: 0, on }
  }
  while (cursor && lines.length <= cursor.line) lines.push([])
  return { lines, cursor }
}

/**
 * The Ghostty font of this video: 16 px on a 22 px line, larger than the
 * kit default, so the agent output reads at a medium zoom. JetBrains Mono
 * advances 0.6 em per character.
 */
export const T = { font: 16, line: 22, pad: 22, cell: 9.6 }

/** Desk px of a character cell in the full codex window: line n, column col. */
export function cell(n, col = 0) {
  return { x: 12 + T.pad + col * T.cell, y: 38 + T.pad + n * T.line + T.line / 2 }
}

/** The camera on the codex dialog. The split clamps it to the top left corner. */
export const CAM_DIALOG = { z: 1.3, cx: 380, cy: 260 }
export const CAM_WIDE = { z: 1.0, cx: 720, cy: 450 }
export const CAM_MID = { z: 1.15, cx: 560, cy: 380 }

/**
 * The split frame with workspace 一 and the codex agent in one Ghostty
 * window that fills the tiled area. layout 'full' is the codex window
 * only. layout 'split' puts codex on the left and a new shell on the right.
 */
export function buildDesk(layer, { screens = SCREENS, layout = 'full' } = {}) {
  const s = split(layer, { wallpaper: '3-sunset-lake', bar: { focused: 1, occupied: [1] }, screens })
  // Chromium clips the rounded screen corners on a stable path only with
  // its own compositing layer, as in the earlier video.
  css(s.phone.screen, { willChange: 'transform' })
  const full = layout === 'full'
  const codex = hyprWindow({ x: 10, y: 36, w: full ? 1420 : 704, h: 854, active: full, opacity: 0.985 })
  const term = terminal({ w: full ? 1416 : 700, h: 850, font: T.font, lineH: T.line, pad: T.pad })
  codex.content.append(term.el)
  s.desk.windows.append(codex.el)
  let shell = null
  if (!full) {
    const win = hyprWindow({ x: 726, y: 36, w: 704, h: 854, active: true, opacity: 0.985 })
    const t = terminal({ w: 700, h: 850, font: T.font, lineH: T.line, pad: T.pad })
    win.content.append(t.el)
    s.desk.windows.append(win.el)
    shell = { win, term: t }
  }
  return { s, codex, term, shell }
}

/**
 * The output box of the codex screen after the answer, in capture px: a
 * cover over the old dialog, and the new lines of the agent in the font and
 * the line grid of the capture. Droid Sans Mono at 29.8 px advances 17.9 px
 * from x 60, and the rows are 42.2 px apart from y 477.6. The new lines take
 * rows 6 to 10, after the dry run in rows 3 and 4. set(cover, lines) sets
 * the 2 opacities.
 */
export function phoneOutput(overlay) {
  const cover = h('div', { style: { position: 'absolute', left: 40, top: 700, width: 1000, height: 970, background: '#1a1b26', visibility: 'hidden' } })
  const span = (t, style = '') => `<span style="${style}">${t}</span>`
  const rows = [
    span('●', 'color:#9ece6a') + ' ' + span('Bash', 'font-weight:700') + '(bin/migrate --apply)',
    '  ' + span('⎿', 'color:#414868') + '  Applied ' + span('0042_add_invoice_status', 'color:#7dcfff'),
    '',
    span('●', 'color:rgb(215,119,87)') + ' The migration is applied. The invoices table has a',
    'status column now.',
  ]
  const lines = h('div', {
    style: {
      position: 'absolute', left: 60, top: 477.6 + 6 * 42.2, fontFamily: "'Droid Sans Mono', monospace", fontSize: 29.8,
      lineHeight: '42.2px', whiteSpace: 'pre', color: '#c0caf5', visibility: 'hidden',
    },
    html: rows.map((r) => r || ' ').join('\n'),
  })
  overlay.prepend(cover, lines)
  return {
    set(c, l) {
      cover.style.opacity = String(c)
      cover.style.visibility = c > 0.001 ? 'visible' : 'hidden'
      lines.style.opacity = String(l)
      lines.style.visibility = l > 0.001 ? 'visible' : 'hidden'
    },
  }
}

/** Draws the codex output for video frame g. */
export function drawAgent(term, g) {
  const { lines, cursor } = agentOutput(g)
  term.render(lines, cursor)
}

export { prompt, TERM }
