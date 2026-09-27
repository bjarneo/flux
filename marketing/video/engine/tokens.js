// Design tokens. Omarchy values come from the live Tokyo Night theme
// (survey.json, look). Video values are for the marketing layer.

export const C = {
  // Omarchy Tokyo Night
  bg: '#1a1b26',
  bg2: '#13141c',
  bg3: '#292e42',
  bgDarker: '#0e0e14',
  bgLighter: '#24283b',
  fg: '#a9b1d6',
  fgBright: '#c0caf5',
  fgDark: '#565f89',
  dim: '#707590',
  muted: '#414868',
  accent: '#7aa2f7',
  ok: '#9ece6a',
  warn: '#e0af68',
  err: '#f7768e',
  alt: '#ad8ee6',
  cyan: '#449dab',
  notifBody: '#939aba',
  borderInactive: 'rgba(89,89,89,0.667)',
  // Video layer
  ink: '#e6e9f5',
  inkDim: '#8b91b4',
  stage: '#0b0c12',
}

export const FONT = {
  sans: "'Inter', sans-serif",
  mono: "'JetBrainsMono Nerd Font', 'JetBrains Mono', monospace",
  notif: "'Liberation Sans', sans-serif",
  cjk: "'Noto Sans Mono CJK KR', 'JetBrainsMono Nerd Font', monospace",
  omarchy: "'omarchy'",
}

export const ASSET = 'assets'

// The Omarchy desktop is 1440x900 logical px, like the real display.
export const DESK = { w: 1440, h: 900, bar: 26, gapOut: 10, gapIn: 6, border: 2 }

// The phone screen is 1080x2400 px, like the captures.
export const PHONE = { w: 1080, h: 2400 }

// Hyprland animation curves from the live config.
export const HYPR = {
  easeOutQuint: [0.23, 1, 0.32, 1],
  windowsInMs: 410,
  fadeInMs: 173,
  layersInMs: 400,
  wipeMs: 420,
}

/** A cubic-bezier easing function, like CSS cubic-bezier(). */
export function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
  const sx = (t) => ((ax * t + bx) * t + cx) * t
  const sy = (t) => ((ay * t + by) * t + cy) * t
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx
  return (x) => {
    if (x <= 0) return 0
    if (x >= 1) return 1
    let t = x
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - x
      if (Math.abs(e) < 1e-6) break
      const d = dx(t)
      if (Math.abs(d) < 1e-6) break
      t -= e / d
    }
    return sy(t)
  }
}

export const hyprQuint = bezier(0.23, 1, 0.32, 1)
