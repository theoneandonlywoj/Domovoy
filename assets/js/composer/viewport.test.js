import assert from "node:assert/strict"
import {test} from "node:test"
import {screenToWorld, zoomRange} from "./geometry.js"
import {FIT_FLOOR, actualSize, fitSelection, fitView, initial, panBy, reveal, transform, wheel} from "./viewport.js"

const box = (left, top, width = 200, height = 100) => ({left, top, right: left + width, bottom: top + height})

// A world box's rect on screen, under `view`.
const onScreen = (view, {left, top, right, bottom}) => ({
  left: left * view.zoom + view.x,
  right: right * view.zoom + view.x,
  top: top * view.zoom + view.y,
  bottom: bottom * view.zoom + view.y,
})

const inside = ({left, top, right, bottom}, {width, height}, padding = 0) =>
  left >= padding && top >= padding && right <= width - padding && bottom <= height - padding

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

test("a pinch with a fit lands on relative 5% steps and stops at the fit's range", () => {
  const fit = 0.5
  const point = {x: 100, y: 100}
  const pinch = (view, deltaY) => wheel(view, {deltaX: 0, deltaY, ctrlKey: true}, point, fit)
  let view = {x: 0, y: 0, zoom: fit}
  for (let i = 0; i < 20; i++) {
    view = pinch(view, -30)
    const steps = (view.zoom / fit) * 20
    assert.ok(Math.abs(steps - Math.round(steps)) < 1e-9, String(view.zoom))
  }
  for (let i = 0; i < 50; i++) view = pinch(view, -100)
  assert.equal(view.zoom, zoomRange(fit).max)
  for (let i = 0; i < 50; i++) view = pinch(view, 100)
  assert.equal(view.zoom, zoomRange(fit).min)
})

test("a large graph shrinks until every card is inside the padded canvas", () => {
  const canvas = {width: 1248, height: 860}
  const boxes = [box(0, 0), box(3000, 200), box(1500, 2000)]
  const view = fitView(boxes, canvas)
  assert.ok(view.zoom < 1)
  for (const card of boxes) assert.ok(inside(onScreen(view, card), canvas, 63.999))
})

test("a small graph keeps real size", () => {
  const view = fitView([box(0, 0), box(300, 0)], {width: 1248, height: 860})
  assert.equal(view.zoom, 1)
})

test("negative coordinates come into view at scale 1", () => {
  const canvas = {width: 1248, height: 860}
  const boxes = [box(-300, -100), box(100, 50)]
  const view = fitView(boxes, canvas)
  assert.equal(view.zoom, 1)
  for (const card of boxes) assert.ok(inside(onScreen(view, card), canvas))
})

test("nothing to fit, or nowhere to fit it, gives the initial view", () => {
  assert.deepEqual(fitView([], {width: 800, height: 600}), initial())
  assert.deepEqual(fitView([box(0, 0)], {width: 0, height: 600}), initial())
  assert.deepEqual(fitView([box(0, 0)], {width: 800, height: 0}), initial())
})

test("a zero-size box on a canvas with no room beyond its padding stays finite and positive", () => {
  const view = fitView([box(10, 10, 0, 0)], {width: 128, height: 128})
  for (const value of [view.x, view.y, view.zoom]) assert.ok(Number.isFinite(value))
  assert.ok(view.zoom > 0)
})

test("an outlier stops the scale at the floor and keeps the nearby cards in view", () => {
  const canvas = {width: 1248, height: 860}
  for (const outlier of [20000, -20000]) {
    const near = [box(0, 0), box(400, 0)]
    const view = fitView([...near, box(outlier, 0)], canvas)
    assert.equal(view.zoom, FIT_FLOOR)
    for (const card of near) assert.ok(inside(onScreen(view, card), canvas), String(outlier))
  }
})

test("a graph too big on both axes still shows a whole card at the floor", () => {
  const canvas = {width: 1248, height: 860}
  const boxes = [box(0, 20000), box(20000, 0), box(40000, 40000)]
  const view = fitView(boxes, canvas)
  assert.equal(view.zoom, FIT_FLOOR)
  assert.ok(boxes.some(card => inside(onScreen(view, card), canvas)))
})

test("the transform translates then scales", () => {
  assert.equal(transform({x: 1, y: 2, zoom: 0.5}), "translate(1px, 2px) scale(0.5)")
})

test("reveal keeps the same view when the box is visible, so opening a panel can't refit", () => {
  const view = {x: 40, y: 20, zoom: 0.5}
  assert.equal(reveal(view, box(100, 100), {left: 0, top: 0, right: 500, bottom: 400}), view)
})

test("reveal pans just enough to bring an occluded box inside the visible rect", () => {
  const view = {x: 0, y: 0, zoom: 0.5}
  // Screen 300..400 wide, 50..100 tall, under a panel from 350.
  assert.deepEqual(reveal(view, box(600, 100), {left: 0, top: 0, right: 350, bottom: 400}), {x: -50, y: 0, zoom: 0.5})
  assert.deepEqual(reveal(view, box(-100, -40), {left: 0, top: 0, right: 350, bottom: 400}), {x: 50, y: 20, zoom: 0.5})
})

test("Actual size is true scale 1, which shows as 100 / fit percent", () => {
  const fit = 0.62
  const centre = {x: 400, y: 300}
  const next = actualSize({x: 10, y: 20, zoom: fit}, centre, fit)
  assert.equal(next.zoom, 1)
  assert.equal(Math.round((next.zoom / fit) * 100), 161)
  const world = screenToWorld({x: 10, y: 20, zoom: fit}, centre)
  assert.deepEqual(screenToWorld(next, centre), world)
})

test("Fit selection centres one box and never enlarges it", () => {
  const canvas = {width: 800, height: 600}
  const next = fitSelection(box(1000, 500), canvas)
  assert.equal(next.zoom, 1)
  assert.ok(inside(onScreen(next, box(1000, 500)), canvas, 64))
})
