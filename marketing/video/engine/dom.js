// Small DOM helpers for scenes.

const PX = new Set(['left', 'top', 'right', 'bottom', 'width', 'height', 'fontSize', 'borderRadius',
  'padding', 'margin', 'gap', 'lineHeight', 'letterSpacing', 'borderWidth', 'minWidth', 'minHeight',
  'maxWidth', 'maxHeight', 'paddingLeft', 'paddingRight', 'paddingTop', 'paddingBottom',
  'marginLeft', 'marginRight', 'marginTop', 'marginBottom'])

/** Sets inline styles. Numbers get px for length properties. */
export function css(el, styles) {
  for (const [k, v] of Object.entries(styles)) {
    if (v === undefined) continue
    el.style[k] = typeof v === 'number' && PX.has(k) ? `${v}px` : v
  }
  return el
}

/**
 * Creates an element. props: class, style (object), text, html, and any
 * attribute. Children are nodes or strings.
 */
export function h(tag, props = {}, ...children) {
  const svg = ['svg', 'path', 'rect', 'circle', 'g', 'line', 'polyline', 'polygon', 'defs', 'linearGradient',
    'radialGradient', 'stop', 'clipPath', 'mask', 'ellipse', 'text', 'filter', 'feGaussianBlur'].includes(tag)
  const el = svg ? document.createElementNS('http://www.w3.org/2000/svg', tag) : document.createElement(tag)
  for (const [k, v] of Object.entries(props || {})) {
    if (v === undefined || v === null || v === false) continue
    if (k === 'class') el.setAttribute('class', v)
    else if (k === 'style') typeof v === 'string' ? (el.style.cssText = v) : css(el, v)
    else if (k === 'text') el.textContent = v
    else if (k === 'html') el.innerHTML = v
    else el.setAttribute(k, v)
  }
  for (const c of children.flat()) {
    if (c === undefined || c === null || c === false) continue
    el.append(c instanceof Node ? c : document.createTextNode(String(c)))
  }
  return el
}

/** An absolutely positioned box. */
export const box = (x, y, w, h_, props = {}, ...children) =>
  h('div', { ...props, style: { position: 'absolute', left: x, top: y, width: w, height: h_, ...(props.style || {}) } }, ...children)

/**
 * Sets transform and opacity in one call. x and y in px, s is the scale,
 * r is the rotation in degrees, o is the opacity, blur in px.
 */
export function place(el, { x = 0, y = 0, s = 1, sx, sy, r = 0, o, blur } = {}) {
  const scale = sx !== undefined || sy !== undefined ? `scale(${sx ?? s}, ${sy ?? s})` : `scale(${s})`
  el.style.transform = `translate(${x}px, ${y}px) ${scale} rotate(${r}deg)`
  if (o !== undefined) {
    el.style.opacity = String(o)
    el.style.visibility = o <= 0.001 ? 'hidden' : 'visible'
  }
  if (blur !== undefined) el.style.filter = blur > 0.05 ? `blur(${blur}px)` : 'none'
  return el
}

/** Shows or hides an element without a layout change. */
export const show = (el, on) => {
  el.style.visibility = on ? 'visible' : 'hidden'
  return el
}
