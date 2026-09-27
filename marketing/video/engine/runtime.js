// Mounts the scenes of the timeline and renders one frame on request.
//
// A scene module exports default { id, duration, mount(layer, props), update(refs, f, ctx) }.
// mount builds the DOM once, with every <img> it needs, and returns refs.
// update sets styles for the local frame f in [0, duration). It must not
// create images, read the clock, or use CSS transitions or animations.

import { FPS } from './anim.js'

// timeline.js lists { file, overlap, props } entries. Only the scenes that
// render get imported, so a broken scene file does not stop the others.

const W = 1920, H = 1080
const stage = document.getElementById('stage')
const params = new URLSearchParams(location.search)
// ?timeline=herdr loads timeline-herdr.js. Each video has its own timeline.
const timeline = (await import(`../timeline-${params.get('timeline') || 'herdr'}.js`)).default
const only = params.get('scene')
const file = params.get('file')

const entries = []
let end = 0
// ?file=scenes/x.js renders one scene file that timeline.js does not list yet.
const wanted = file ? [{ id: 'file', file }] : timeline.filter((item) => !only || item.id === only)
if (only && !wanted.length) window.__error = `no scene ${only} in timeline.js`
const modules = await Promise.all(wanted.map((item) => import(`../${item.file}`)))
for (const [i, item] of wanted.entries()) {
  const scene = modules[i].default
  const overlap = only || file ? 0 : item.overlap || 0
  const start = entries.length ? end - overlap : 0
  const layer = document.createElement('div')
  layer.className = 'layer'
  layer.dataset.scene = scene.id
  stage.append(layer)
  const props = item.props || {}
  const refs = scene.mount(layer, props)
  entries.push({ scene, start, layer, refs, props })
  end = start + scene.duration
}

window.__meta = {
  fps: FPS, width: W, height: H, frames: end,
  scenes: entries.map((e) => ({ id: e.scene.id, start: e.start, frames: e.scene.duration })),
}

window.renderFrame = (n) => {
  for (const e of entries) {
    const local = n - e.start
    const active = local >= 0 && local < e.scene.duration
    e.layer.style.display = active ? 'block' : 'none'
    if (active) e.scene.update(e.refs, local, { global: n, props: e.props })
  }
}

async function ready() {
  // Load every declared face, also the ones that only show in later frames.
  void document.body.offsetHeight
  await Promise.all([...document.fonts].map((face) => face.load().catch(() => null)))
  await document.fonts.ready
  const imgs = [...stage.querySelectorAll('img')]
  const failed = []
  await Promise.all(imgs.map((i) => i.decode().catch(() => failed.push(i.getAttribute('src')))))
  if (failed.length) throw new Error(`images failed to load: ${failed.join(', ')}`)
}

ready()
  .then(() => {
    window.renderFrame(Number(params.get('f') || 0))
    window.__ready = true
    if (params.has('play')) play()
  })
  .catch((err) => {
    window.__error = String(err && err.stack ? err.stack : err)
    console.error(window.__error)
  })

// Real-time preview in a normal browser: index.html?play or ?play&scene=id
function play() {
  const t0 = performance.now()
  const tick = () => {
    const n = Math.floor(((performance.now() - t0) / 1000) * FPS) % end
    window.renderFrame(n)
    requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}
