import fs from 'node:fs'
const buf = fs.readFileSync('mono.f32'); const x = new Float32Array(buf.buffer, buf.byteOffset, buf.length/4)
const sr = 11025, hop = 256, win = 1024
const n = Math.floor((x.length - win) / hop)
// energy envelope and spectral-flux-like onset (log energy diff)
const e = new Float32Array(n)
for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < win; j++) { const v = x[i*hop+j]; s += v*v } e[i] = Math.log(1e-9 + s / win) }
const on = new Float32Array(n); for (let i = 1; i < n; i++) on[i] = Math.max(0, e[i]-e[i-1])
const fps = sr / hop
// loudness per 2 s
const rows = []
for (let t = 0; t < x.length / sr; t += 2) { let s = 0, c = 0; for (let k = Math.floor(t*sr); k < Math.min(x.length, (t+2)*sr); k++) { s += x[k]*x[k]; c++ } rows.push([t, 10*Math.log10(s/c+1e-12)]) }
console.log('loudness dB per 2s:'); console.log(rows.map(([t,d]) => `${String(t).padStart(3)}s ${d.toFixed(1).padStart(6)} ${'#'.repeat(Math.max(0, Math.round((d+40)/1)))}`).join('\n'))
// tempo via autocorrelation of onset over 60..180 bpm
function tempo(a, b) {
  const seg = on.slice(Math.floor(a*fps), Math.floor(b*fps)); let best = 0, bl = 0; const res = []
  for (let bpm = 60; bpm <= 180; bpm += 0.25) { const lag = fps * 60 / bpm; let s = 0; for (let i = 0; i + lag + 1 < seg.length; i++) { const l0 = Math.floor(lag), fr = lag - l0; s += seg[i] * (seg[i+l0]*(1-fr) + seg[i+l0+1]*fr) } res.push([bpm, s]); if (s > best) { best = s; bl = bpm } }
  return bl
}
console.log('tempo 0-60', tempo(0,60), '60-120', tempo(60,120), '120-180', tempo(120,180), 'all', tempo(0, x.length/sr - 1))
fs.writeFileSync('onset.json', JSON.stringify({ fps, on: Array.from(on).map(v => +v.toFixed(3)) }))
