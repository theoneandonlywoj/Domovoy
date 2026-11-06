import assert from "node:assert/strict"
import {test} from "node:test"
import {MAX_ZOOM, MIN_ZOOM, clampZoom, cubicPath, screenToWorld, snapZoom, socketPoint, zoomAt} from "./geometry.js"

const view = {x: 30, y: -20, zoom: 0.5}

test("a screen point converts to world coordinates through the pan and zoom", () => {
  assert.deepEqual(screenToWorld(view, {x: 130, y: 80}), {x: 200, y: 200})
})

test("zoom clamps to its range", () => {
  assert.equal(clampZoom(100), MAX_ZOOM)
  assert.equal(clampZoom(0), MIN_ZOOM)
  assert.equal(clampZoom(1), 1)
})

test("zoom snaps to the nearest 5% within its range", () => {
  assert.equal(snapZoom(1.01), 1)
  assert.equal(snapZoom(1.03), 1.05)
  assert.equal(snapZoom(0.1), MIN_ZOOM)
  assert.equal(snapZoom(5), MAX_ZOOM)
})

test("zoomAt keeps the world point under the pointer", () => {
  const point = {x: 200, y: 150}
  const next = zoomAt(view, point, 1.5)
  assert.equal(next.zoom, 1.5)
  assert.deepEqual(screenToWorld(next, point), screenToWorld(view, point))
})

test("a socket's point is its centre in world coordinates, zoomed or not", () => {
  const origin = {left: 100, top: 50}
  const rect = {left: 200, top: 150, width: 12, height: 12}
  assert.deepEqual(socketPoint(rect, origin, 1), {x: 106, y: 106})
  assert.deepEqual(socketPoint(rect, origin, 2), {x: 53, y: 53})
})

test("a wire starts and ends exactly on its points", () => {
  const d = cubicPath({x: 1, y: 2}, {x: 300, y: 4})
  assert.match(d, /^M 1 2 C /)
  assert.match(d, / 300 4$/)
})
