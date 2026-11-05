// Screen and world coordinates. A view is {x, y, zoom}: world point (0, 0) sits at
// screen point (x, y) relative to the canvas.

export const MIN_ZOOM = 0.25
export const MAX_ZOOM = 2

export const clampZoom = zoom => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom))

export const screenToWorld = (view, point) => ({
  x: (point.x - view.x) / view.zoom,
  y: (point.y - view.y) / view.zoom,
})

// Zooms keeping the world point under `point` where it is.
export function zoomAt(view, point, zoom) {
  const next = clampZoom(zoom)
  const world = screenToWorld(view, point)
  return {x: point.x - world.x * next, y: point.y - world.y * next, zoom: next}
}

// The centre of a socket's client rect in world coordinates. `origin` is the world
// element's own client rect, so this holds however the canvas got scrolled or moved.
export const socketPoint = (rect, origin, zoom) => ({
  x: (rect.left + rect.width / 2 - origin.left) / zoom,
  y: (rect.top + rect.height / 2 - origin.top) / zoom,
})

export function cubicPath(from, to) {
  const bend = Math.max(40, Math.abs(to.x - from.x) / 2)
  return `M ${from.x} ${from.y} C ${from.x + bend} ${from.y}, ${to.x - bend} ${to.y}, ${to.x} ${to.y}`
}

const LOOP_REACH = 48

// A wire to something further left would run behind the cards, as they sit above the
// wire layer, so it leaves each socket outward and crosses at `below`, under them.
export function loopPath(from, to, below) {
  const out = from.x + LOOP_REACH
  const back = to.x - LOOP_REACH
  return `M ${from.x} ${from.y} C ${out} ${from.y}, ${out} ${below}, ${from.x} ${below} L ${to.x} ${below} C ${back} ${below}, ${back} ${to.y}, ${to.x} ${to.y}`
}

// An element's client rect in world coordinates.
export const worldBox = (rect, origin, zoom) => ({
  left: (rect.left - origin.left) / zoom,
  right: (rect.right - origin.left) / zoom,
  bottom: (rect.bottom - origin.top) / zoom,
})
