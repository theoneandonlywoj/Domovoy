// Pan and zoom. Nothing here is saved: a reload starts at the initial view.
import {zoomAt} from "./geometry.js"

const WHEEL_ZOOM_RATE = 0.002

export const initial = () => ({x: 0, y: 0, zoom: 1})

export const panBy = (view, dx, dy) => ({...view, x: view.x + dx, y: view.y + dy})

// A pinch or Ctrl/Cmd+wheel zooms at the pointer; any other wheel pans.
export function wheel(view, {deltaX, deltaY, ctrlKey, metaKey}, point) {
  if (ctrlKey || metaKey) return zoomAt(view, point, view.zoom * Math.exp(-deltaY * WHEEL_ZOOM_RATE))
  return panBy(view, -deltaX, -deltaY)
}

export const transform = view => `translate(${view.x}px, ${view.y}px) scale(${view.zoom})`
