import assert from "node:assert/strict"
import {test} from "node:test"
import {screenToWorld} from "./geometry.js"
import {initial, panBy, transform, wheel} from "./viewport.js"

test("panning moves the view and keeps the zoom", () => {
  assert.deepEqual(panBy({x: 1, y: 2, zoom: 2}, 10, -5), {x: 11, y: -3, zoom: 2})
})

test("a plain wheel pans", () => {
  assert.deepEqual(wheel(initial(), {deltaX: 5, deltaY: 10}, {x: 0, y: 0}), {x: -5, y: -10, zoom: 1})
})

test("Ctrl or Cmd with the wheel zooms at the pointer", () => {
  const point = {x: 100, y: 100}
  for (const modifier of [{ctrlKey: true}, {metaKey: true}]) {
    const next = wheel(initial(), {deltaX: 0, deltaY: -100, ...modifier}, point)
    assert.ok(next.zoom > 1)
    const world = screenToWorld(next, point)
    assert.ok(Math.abs(world.x - 100) < 1e-9 && Math.abs(world.y - 100) < 1e-9)
  }
})

test("wheel zoom lands on 5% steps, and a pinch's small deltas add up to one", () => {
  const point = {x: 100, y: 100}
  const pinch = (view, deltaY) => wheel(view, {deltaX: 0, deltaY, ctrlKey: true}, point)
  assert.equal(pinch(initial(), -100).zoom, 1.2)

  let view = initial()
  const seen = new Set()
  for (let i = 0; i < 20; i++) {
    view = pinch(view, -4)
    seen.add(view.zoom)
  }
  assert.deepEqual([...seen], [1, 1.05, 1.1, 1.15])
})

test("wheel zoom held at a limit reverses at once", () => {
  const pinch = (view, deltaY) => wheel(view, {deltaX: 0, deltaY, ctrlKey: true}, {x: 0, y: 0})
  let view = initial()
  for (let i = 0; i < 50; i++) view = pinch(view, -100)
  assert.equal(view.zoom, 2)
  assert.equal(pinch(view, 100).zoom, 1.65)
})

test("the transform translates then scales", () => {
  assert.equal(transform({x: 1, y: 2, zoom: 0.5}), "translate(1px, 2px) scale(0.5)")
})
