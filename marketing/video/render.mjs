// Renders the timeline with headless Chromium.
//
//   node render.mjs --timeline herdr        full video to out/herdr-master-silent.mp4
//   --timeline herdr or tailscale selects the video. The default is herdr.
//   node render.mjs --scene sudo            one scene to out/scene-sudo.mp4
//   node render.mjs --scene sudo --stills 0,90,180     PNG stills to frames/
//   node render.mjs --scene sudo --sheet 30            contact sheet, 1 frame per 30
//   node render.mjs --sheet 60                         contact sheet of the full video
//   node render.mjs --file scenes/sudo.js --sheet 30   a scene file that timeline.js does not list
//
// Options: --workers N (default 8), --crf N (default 16), --out FILE,
// --from F --to F (frame range), --half (render at 960x540 for a fast check).

import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import puppeteer from 'puppeteer-core'

const ROOT = path.dirname(fileURLToPath(import.meta.url))
const args = parseArgs(process.argv.slice(2))
const TL = typeof args.timeline === 'string' ? args.timeline : 'herdr'
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp',
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.json': 'application/json',
}

function parseArgs(list) {
  const out = {}
  for (let i = 0; i < list.length; i++) {
    const a = list[i]
    if (!a.startsWith('--')) continue
    const key = a.slice(2)
    const next = list[i + 1]
    if (next === undefined || next.startsWith('--')) out[key] = true
    else { out[key] = next; i++ }
  }
  return out
}

function serve() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://x')
      const file = path.join(ROOT, decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname))
      if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
        res.writeHead(404); res.end(); return
      }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' })
      fs.createReadStream(file).pipe(res)
    })
    server.listen(0, '127.0.0.1', () => resolve(server))
  })
}

async function openPage(browser, base, half) {
  const page = await browser.newPage()
  await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: half ? 0.5 : 1 })
  page.on('pageerror', (e) => console.error('[page error]', e.message))
  page.on('console', (m) => {
    if ((m.type() === 'error' || m.type() === 'warn') && !/favicon|404 \(Not Found\)/.test(m.text())) console.error(`[page ${m.type()}]`, m.text())
  })
  const q = new URLSearchParams()
  q.set('timeline', TL)
  if (args.scene) q.set('scene', args.scene)
  if (args.file) q.set('file', args.file)
  await page.goto(`${base}/index.html?${q}`, { waitUntil: 'load' })
  await page.waitForFunction('window.__ready || window.__error', { timeout: 180000, polling: 100 })
  const err = await page.evaluate(() => window.__error)
  if (err) throw new Error(err)
  return page
}

const shot = (page, n) =>
  page.evaluate((n) => window.renderFrame(n), n).then(() =>
    page.screenshot({ type: 'png', optimizeForSpeed: true, captureBeyondViewport: false }))

function ffmpeg(argv) {
  const p = spawn('ffmpeg', argv, { stdio: ['pipe', 'inherit', 'inherit'] })
  const done = new Promise((res, rej) => p.on('exit', (c) => (c === 0 ? res() : rej(new Error(`ffmpeg exit ${c}`)))))
  return { p, done }
}

async function main() {
  const server = await serve()
  const base = `http://127.0.0.1:${server.address().port}`
  // Each worker gets its own browser. A background tab gets no animation
  // frames in headless Chromium, so tabs of one browser stall.
  const browsers = []
  const launch = async () => {
    const b = await puppeteer.launch({
      executablePath: '/usr/bin/chromium',
      headless: true,
      args: ['--hide-scrollbars', '--force-color-profile=srgb', '--font-render-hinting=none', '--disable-lcd-text',
        '--autoplay-policy=no-user-gesture-required', '--disable-background-timer-throttling',
        '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows'],
    })
    browsers.push(b)
    return b
  }
  const browser = await launch()
  try {
    const first = await openPage(browser, base, args.half)
    const meta = await first.evaluate(() => window.__meta)
    const tag = args.scene || (args.file ? args.file.replace(/^.*\//, '').replace(/\.js$/, '') : `${TL}-full`)
    fs.mkdirSync(path.join(ROOT, 'frames'), { recursive: true })
    fs.mkdirSync(path.join(ROOT, 'out'), { recursive: true })

    if (args.stills) {
      const list = String(args.stills).split(',').map(Number)
      for (const n of list) {
        const file = path.join(ROOT, 'frames', `${tag}-${String(n).padStart(5, '0')}.png`)
        fs.writeFileSync(file, await shot(first, n))
        console.log(file)
      }
      return
    }

    if (args.sheet) {
      const every = Number(args.sheet) || 60
      const dir = path.join(ROOT, 'frames', `sheet-${tag}`)
      fs.rmSync(dir, { recursive: true, force: true })
      fs.mkdirSync(dir, { recursive: true })
      const files = []
      for (let n = 0; n < meta.frames; n += every) {
        const file = path.join(dir, `${String(n).padStart(5, '0')}.png`)
        fs.writeFileSync(file, await shot(first, n))
        files.push(file)
      }
      const outFile = path.join(ROOT, 'frames', `sheet-${tag}.png`)
      await new Promise((res, rej) => {
        const p = spawn('magick', ['montage', ...files.flatMap((f) => ['-label', path.basename(f, '.png'), f]),
          '-tile', '4x', '-geometry', '640x360+6+6', '-background', '#111', '-fill', '#ddd', '-pointsize', '18', outFile],
        { stdio: 'inherit' })
        p.on('exit', (c) => (c === 0 ? res() : rej(new Error('montage failed'))))
      })
      console.log(`${outFile} (${files.length} frames, every ${every})`)
      return
    }

    const from = Number(args.from || 0)
    const to = Math.min(Number(args.to || meta.frames), meta.frames)
    const workers = Math.max(1, Math.min(Number(args.workers || 8), to - from))
    const crf = String(args.crf || 16)
    const size = args.half ? '960x540' : '1920x1080'
    const chunk = Math.ceil((to - from) / workers)
    const segDir = path.join(ROOT, 'out', `seg-${tag}`)
    fs.rmSync(segDir, { recursive: true, force: true })
    fs.mkdirSync(segDir, { recursive: true })
    console.log(`rendering ${tag}: frames ${from}-${to} of ${meta.frames}, ${workers} workers, ${size}`)
    const t0 = Date.now()
    let doneFrames = 0
    const segs = []
    await Promise.all(Array.from({ length: workers }, async (_, w) => {
      const a = from + w * chunk
      const b = Math.min(to, a + chunk)
      if (a >= b) return
      const seg = path.join(segDir, `${String(w).padStart(3, '0')}.mp4`)
      segs[w] = seg
      const page = w === 0 ? first : await openPage(await launch(), base, args.half)
      const { p, done } = ffmpeg(['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(meta.fps),
        '-c:v', 'png', '-i', '-', '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
        '-c:v', 'libx264', '-preset', 'medium', '-crf', crf, '-g', String(meta.fps * 2),
        '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv', seg])
      for (let n = a; n < b; n++) {
        const buf = await shot(page, n)
        if (!p.stdin.write(buf)) await new Promise((r) => p.stdin.once('drain', r))
        doneFrames++
        if (doneFrames % 300 === 0) {
          const s = (Date.now() - t0) / 1000
          console.log(`  ${doneFrames}/${to - from} frames, ${(doneFrames / s).toFixed(1)} fps`)
        }
      }
      p.stdin.end()
      await done
    }))
    const list = path.join(segDir, 'list.txt')
    fs.writeFileSync(list, segs.filter(Boolean).map((s) => `file '${s}'`).join('\n'))
    const out = args.out ? path.resolve(args.out) : path.join(ROOT, 'out', tag !== `${TL}-full` ? `scene-${tag}.mp4` : `${TL}-master-silent.mp4`)
    await ffmpeg(['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', '-movflags', '+faststart', out]).done
    console.log(`${out} in ${((Date.now() - t0) / 1000).toFixed(1)} s`)
  } finally {
    await Promise.all(browsers.map((b) => b.close()))
    server.close()
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
