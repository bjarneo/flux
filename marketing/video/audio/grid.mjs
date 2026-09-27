import fs from 'node:fs'
const { fps, on } = JSON.parse(fs.readFileSync('onset.json'))
const at = (t) => { const i = t * fps, i0 = Math.floor(i), f = i - i0; return (on[i0]||0)*(1-f) + (on[i0+1]||0)*f }
function fit(a, b, lo, hi) {
  let best = { s: -1 }
  for (let bpm = lo; bpm <= hi; bpm += 0.01) {
    const per = 60 / bpm
    for (let ph = 0; ph < per; ph += 0.002) { let s = 0, n = 0; for (let t = a + ph; t < b; t += per) { s += at(t); n++ } s /= n; if (s > best.s) best = { s, bpm, ph, per } }
  }
  return best
}
for (const [a, b] of [[0, 24], [28, 78], [82, 128]]) for (const [lo, hi] of [[66, 72], [132, 142]]) {
  const r = fit(a, b, lo, hi); console.log(`${a}-${b}s ${lo}-${hi}: bpm ${r.bpm.toFixed(2)} first beat ${(a + r.ph).toFixed(3)} score ${r.s.toFixed(3)}`)
}
const buf = fs.readFileSync('mono.f32'); const x = new Float32Array(buf.buffer, buf.byteOffset, buf.length/4); const sr = 11025
const row = (a, z, d) => { const r = []; for (let t = a; t < z; t += d) { let s = 0, c = 0; for (let k = Math.floor(t*sr); k < (t+d)*sr; k++) { s += x[k]*x[k]; c++ } r.push(`${t.toFixed(2)}:${(10*Math.log10(s/c)).toFixed(0)}`) } return r.join(' ') }
console.log('\n0-4\n' + row(0, 4, 0.25)); console.log('\n21-30\n' + row(21, 30, 0.25)); console.log('\n75-84\n' + row(75, 84, 0.25))
