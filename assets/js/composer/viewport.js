// Pan and zoom. Nothing here is saved: a reload fits the level again.
import {clampZoom, snapZoom, zoomAt, zoomRange} from "./geometry.js"

const WHEEL_ZOOM_RATE = 0.002
const FIT_PADDING = 64

export const FIT_FLOOR = 0.1

export const initial = () => ({x: 0, y: 0, zoom: 1})

export const panBy = (view, dx, dy) => ({...view, x: view.x + dx, y: view.y + dy})

// A pinch or Ctrl/Cmd+wheel zooms at the pointer; any other wheel pans. The zoom lands on
// a slider step, and `wheelZoom` keeps the unsnapped value, because a pinch's small
// deltas would otherwise each round back to the step they started from.
export function wheel(view, {deltaX, deltaY, ctrlKey, metaKey}, point, fit = 1) {
  if (ctrlKey || metaKey) {
    const wheelZoom = clampZoom((view.wheelZoom ?? view.zoom) * Math.exp(-deltaY * WHEEL_ZOOM_RATE), zoomRange(fit))
    return {...zoomAt(view, point, snapZoom(wheelZoom, fit), fit), wheelZoom}
  }
  return panBy(view, -deltaX, -deltaY)
}

// Below the floor a whole span can't fit, and its midpoint may show only the empty
// space between far cards. So every axis that overflows centres on one anchor card, the
// lower median by x, which keeps that card in view on both axes.
function anchorCard(boxes) {
  const byX = [...boxes].sort((a, b) => a.left + a.right - b.left - b.right)
  return byX[Math.floor((byX.length - 1) / 2)]
}

// The view that centres `boxes`, world boxes {left, top, right, bottom}, inside `canvas`,
// {width, height}. It never enlarges them, and it translates even at scale 1, so negative
// coordinates come into view. The padding covers socket overhang, loop wires and the
// corner overlays.
export function fitView(boxes, {width, height}) {
  if (boxes.length === 0 || width <= 0 || height <= 0) return initial()
  const left = Math.min(...boxes.map(box => box.left))
  const right = Math.max(...boxes.map(box => box.right))
  const top = Math.min(...boxes.map(box => box.top))
  const bottom = Math.max(...boxes.map(box => box.bottom))
  const roomX = width - 2 * FIT_PADDING
  const roomY = height - 2 * FIT_PADDING
  const zoom = Math.max(FIT_FLOOR, Math.min(
    1,
    roomX / Math.max(1, right - left),
    roomY / Math.max(1, bottom - top),
  ))
  const atFloor = zoom === FIT_FLOOR
  const anchor = anchorCard(boxes)
  const centreX = atFloor && (right - left) * zoom > roomX ? (anchor.left + anchor.right) / 2 : (left + right) / 2
  const centreY = atFloor && (bottom - top) * zoom > roomY ? (anchor.top + anchor.bottom) / 2 : (top + bottom) / 2
  return {x: width / 2 - centreX * zoom, y: height / 2 - centreY * zoom, zoom}
}

// True scale 1 at `centre`, so the percentage shows 100 / fit. Small graphs fit at 1 already.
export const actualSize = (view, centre, fit) => zoomAt(view, centre, 1, fit)

export const fitSelection = (box, canvas) => fitView([box], canvas)

// The smallest pan bringing a world box inside `visible`, a rect in canvas coordinates;
// the same view when it is already inside.
export function reveal(view, box, visible) {
  const left = box.left * view.zoom + view.x, right = box.right * view.zoom + view.x
  const top = box.top * view.zoom + view.y, bottom = box.bottom * view.zoom + view.y
  const dx = left < visible.left ? visible.left - left : right > visible.right ? visible.right - right : 0
  const dy = top < visible.top ? visible.top - top : bottom > visible.bottom ? visible.bottom - bottom : 0
  return dx === 0 && dy === 0 ? view : panBy(view, dx, dy)
}

export const transform = view => `translate(${view.x}px, ${view.y}px) scale(${view.zoom})`
