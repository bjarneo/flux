// The Flux website. Each part works without this script: the clocks show
// their time as text, the first screen shows, and the links work.

document.documentElement.classList.add('js')

const still = window.matchMedia('(prefers-reduced-motion: reduce)')

// The Flux mark traces in: the ring side by side, then the bar.
function draw(mark) {
  if (still.matches) {
    mark.classList.add('is-drawn')
    return
  }
  mark.classList.add('is-drawing')
  mark.addEventListener('animationend', (e) => {
    if (e.target.classList.contains('b')) mark.classList.add('is-drawn')
  })
}

// A clock is a row of digit reels. set() rolls each reel to its digit.
function clock(el) {
  const reels = []
  el.textContent = ''
  for (const ch of el.dataset.clock) {
    if (ch === ':') {
      el.append(Object.assign(document.createElement('span'), { className: 'colon', textContent: ':' }))
      continue
    }
    const reel = document.createElement('span')
    reel.className = 'reel'
    const strip = document.createElement('span')
    strip.className = 'strip'
    for (let d = 0; d <= 9; d++) strip.append(Object.assign(document.createElement('span'), { textContent: String(d) }))
    reel.append(strip)
    el.append(reel)
    reels.push(strip)
  }
  const set = (time) => {
    const digits = time.replace(':', '')
    reels.forEach((strip, i) => strip.style.setProperty('--n', digits[i]))
  }
  return { set }
}

// The first viewport: the mark draws, and the clock rolls up to 14:07.
draw(document.querySelector('.bar [data-mark]'))
const hero = document.querySelector('.clock-hero')
if (hero) {
  const c = clock(hero)
  if (still.matches) {
    c.set(hero.dataset.clock)
  } else {
    c.set('00:00')
    requestAnimationFrame(() => requestAnimationFrame(() => c.set(hero.dataset.clock)))
  }
}

// The end card draws its mark when it comes into view.
const late = document.querySelector('[data-mark-late]')
if (late) {
  new IntersectionObserver((entries, io) => {
    if (entries.some((e) => e.isIntersecting)) {
      draw(late)
      io.disconnect()
    }
  }, { threshold: 0.6 }).observe(late)
}

// The afternoon: the moment in the middle of the window takes the focus.
// The rail clock rolls to its time, and the phone shows its screen.
const moments = [...document.querySelectorAll('.moment')]
const railClock = document.querySelector('[data-rail-clock]')
const railNow = document.querySelector('[data-rail-now]')
const railItems = [...document.querySelectorAll('.rail-list li')]
const stage = [...document.querySelectorAll('[data-stage] img')]
const rc = railClock ? clock(railClock) : null
rc?.set(railClock.dataset.clock)

function focus(m) {
  const i = moments.indexOf(m)
  rc?.set(m.dataset.time)
  if (railNow) railNow.textContent = m.dataset.label
  railItems.forEach((li, j) => {
    li.classList.toggle('is-on', j === i)
    li.classList.toggle('is-past', j < i)
  })
  stage.forEach((img) => {
    const on = img.dataset.shot === m.dataset.shot
    if (on) img.loading = 'eager'
    img.classList.toggle('is-on', on)
  })
}

// Like the focus in Hyprland, 1 tile at a time carries the active border:
// the tile at the middle of the window, or else the visible tile nearest to
// it. A scroll of any kind, a jump to an anchor, and a resize update it.
const tiles = [...document.querySelectorAll('[data-focus]')]
let current = null
let queued = false

function pick() {
  queued = false
  const mid = window.innerHeight / 2
  let best = null
  let gap = Infinity
  for (const t of tiles) {
    const r = t.getBoundingClientRect()
    if (r.bottom < 0 || r.top > window.innerHeight) continue
    const d = r.top <= mid && r.bottom >= mid ? 0 : Math.min(Math.abs(r.top - mid), Math.abs(r.bottom - mid))
    if (d < gap) {
      gap = d
      best = t
    }
  }
  if (!best || best === current) return
  current = best
  tiles.forEach((t) => t.classList.toggle('is-focus', t === best))
  if (moments.includes(best)) focus(best)
}

function queue() {
  if (queued) return
  queued = true
  requestAnimationFrame(pick)
}

window.addEventListener('scroll', queue, { passive: true })
window.addEventListener('resize', queue)
window.addEventListener('hashchange', queue)
window.addEventListener('load', queue)
queue()

// The theme section takes the colors of the picked theme, and the phone
// shows the Inbox in that theme.
const themes = document.querySelector('.themes')
if (themes) {
  const chips = [...themes.querySelectorAll('[data-pick]')]
  const shots = [...themes.querySelectorAll('[data-theme-phone] img')]
  chips.forEach((chip) => chip.addEventListener('click', () => {
    const name = chip.dataset.pick
    themes.dataset.theme = name
    chips.forEach((c) => c.setAttribute('aria-pressed', String(c === chip)))
    shots.forEach((img) => {
      const on = img.dataset.shot === name
      if (on) img.loading = 'eager'
      img.classList.toggle('is-on', on)
    })
  }))
}

// Copy buttons.
const status = document.querySelector('[data-copied]')
let hide
document.querySelectorAll('[data-copy]').forEach((btn) => btn.addEventListener('click', async () => {
  const text = btn.dataset.copy
  let ok = true
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    ok = false
  }
  btn.textContent = ok ? 'Copied' : 'Copy failed'
  btn.classList.toggle('is-done', ok)
  if (status) {
    status.textContent = ok ? `Copied: ${text}` : 'The browser did not allow the copy. Select the text and copy it.'
    status.classList.add('is-on')
  }
  clearTimeout(hide)
  hide = setTimeout(() => {
    btn.textContent = 'Copy'
    btn.classList.remove('is-done')
    status?.classList.remove('is-on')
  }, 1800)
}))

// The download links point to the latest release. Without an answer from
// GitHub, they keep the release in the page.
fetch('https://api.github.com/repos/bjarneo/flux/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
  .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
  .then((rel) => {
    const asset = (re) => rel.assets?.find((a) => re.test(a.name))?.browser_download_url
    const links = { android: asset(/^flux-android-.*\.apk$/), mac: asset(/^flux-macos-.*\.zip$/) }
    for (const [key, url] of Object.entries(links)) {
      if (url) document.querySelectorAll(`[data-asset="${key}"]`).forEach((a) => { a.href = url })
    }
    const v = rel.tag_name?.replace(/^v/, '')
    document.querySelectorAll('[data-version]').forEach((a) => {
      if (v) a.textContent = v
      if (rel.html_url) a.href = rel.html_url
    })
  })
  .catch(() => {})
