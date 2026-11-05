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

test("the transform translates then scales", () => {
  assert.equal(transform({x: 1, y: 2, zoom: 0.5}), "translate(1px, 2px) scale(0.5)")
})
