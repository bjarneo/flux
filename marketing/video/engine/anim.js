// Frame-based animation helpers. Every value is a pure function of the
// frame number, so any frame renders the same way in any order.

export const FPS = 60

/** Seconds to frames. */
export const sec = (s) => Math.round(s * FPS)

export const clamp = (x, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, x))
export const lerp = (a, b, t) => a + (b - a) * t

export const ease = {
  linear: (t) => t,
  inCubic: (t) => t * t * t,
  outCubic: (t) => 1 - Math.pow(1 - t, 3),
  inOutCubic: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  outQuint: (t) => 1 - Math.pow(1 - t, 5),
  inOutQuint: (t) => (t < 0.5 ? 16 * t ** 5 : 1 - Math.pow(-2 * t + 2, 5) / 2),
  outExpo: (t) => (t === 1 ? 1 : 1 - Math.pow(2, -10 * t)),
  inOutExpo: (t) =>
    t === 0 ? 0 : t === 1 ? 1 : t < 0.5 ? Math.pow(2, 20 * t - 10) / 2 : (2 - Math.pow(2, -20 * t + 10)) / 2,
  outBack: (t) => {
    const c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2)
  },
  // A smooth camera move: slow start, long soft landing.
  camera: (t) => (t < 0.5 ? 8 * t ** 4 : 1 - Math.pow(-2 * t + 2, 4) / 2),
}

/**
 * Maps f through the keyframes input -> output. The value holds at the
 * first and last output outside the range. easing applies per segment and
 * can be one function or an array with one function per segment.
 */
export function interp(f, input, output, easing = ease.inOutCubic) {
  if (f <= input[0]) return output[0]
  const last = input.length - 1
  if (f >= input[last]) return output[last]
  let i = 0
  while (i < last - 1 && f >= input[i + 1]) i++
  const e = Array.isArray(easing) ? easing[i] : easing
  const t = e((f - input[i]) / (input[i + 1] - input[i]))
  return lerp(output[i], output[i + 1], t)
}

/** 0 -> 1 progress between frames a and b. */
export const progress = (f, a, b, easing = ease.inOutCubic) => easing(clamp((f - a) / (b - a)))

/**
 * A damped spring that starts at frame start. Returns 0 before start and
 * settles at 1. Low damping overshoots.
 */
export function spring(f, start, { stiffness = 180, damping = 22, mass = 1 } = {}) {
  const t = (f - start) / FPS
  if (t <= 0) return 0
  const w0 = Math.sqrt(stiffness / mass)
  const zeta = damping / (2 * Math.sqrt(stiffness * mass))
  if (zeta < 1) {
    const wd = w0 * Math.sqrt(1 - zeta * zeta)
    return 1 - Math.exp(-zeta * w0 * t) * (Math.cos(wd * t) + ((zeta * w0) / wd) * Math.sin(wd * t))
  }
  return 1 - Math.exp(-w0 * t) * (1 + w0 * t)
}

/** Fade in over n frames from frame a, and out over n frames before frame b. */
export function inOut(f, a, b, n = 18) {
  return Math.min(progress(f, a, a + n, ease.outCubic), 1 - progress(f, b - n, b, ease.inCubic))
}

/** The visible part of text typed from frame start at cps characters per second. */
export function typed(text, f, start, cps = 28) {
  const n = Math.floor(((f - start) / FPS) * cps)
  return text.slice(0, clamp(n, 0, text.length))
}

/** True while a text cursor is in the visible half of its blink. */
export const blink = (f, period = 60) => Math.floor(f / (period / 2)) % 2 === 0

/** A deterministic pseudo-random number in [0, 1) for an integer seed. */
export function rand(seed) {
  let x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453
  return x - Math.floor(x)
}
