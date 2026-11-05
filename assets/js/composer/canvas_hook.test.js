import assert from "node:assert/strict"
import {test} from "node:test"
import hook from "./canvas_hook.js"
import * as Drag from "./drag.js"

const element = dataset => ({
  dataset,
  attrs: new Map(),
  hasAttribute(name) { return this.attrs.has(name) },
  getAttribute(name) { return this.attrs.get(name) ?? null },
  setAttribute(name, value) { this.attrs.set(name, value) },
  removeAttribute(name) { this.attrs.delete(name) },
  querySelectorAll: () => [],
})

// The hook's own methods over just the DOM they touch, with a card already dragged.
function dragged(level) {
  const pushes = []
  const pointer = {x: 0, y: 0}
  const moved = Drag.move(Drag.start({from: {x: 10, y: 20}, pointer, zoom: 1, token: 1}), {x: 50, y: 60})
  return Object.assign(Object.create(hook), {
    world: element({level}),
    canvas: element({}),
    composer: element({}),
    notice: {},
    level,
    view: {x: 0, y: 0, zoom: 1},
    moves: new Map([["a", moved]]),
    gesture: {kind: "card", node: "a", pointerId: 1, moved: true},
    liveSocket: {isConnected: () => true},
    scheduleDraw() {},
    pushEvent(name, payload) {
      pushes.push({name, payload})
      return Promise.resolve({status: "ok"})
    },
    pushes,
  })
}

test("a release says which level the card was dragged on", () => {
  const hookState = dragged("stage:main")
  hookState.pointerUp({pointerId: 1, clientX: 50, clientY: 60})

  assert.deepEqual(hookState.pushes, [
    {name: "node_moved", payload: {node: "a", x: 60, y: 80, level: "stage:main"}},
  ])
})

test("a level change ends the gesture, so its release moves nothing", () => {
  const hookState = dragged("stage:main")
  hookState.world.dataset.level = "workflow"

  hookState.sync()
  assert.equal(hookState.gesture, null)

  hookState.pointerUp({pointerId: 1, clientX: 50, clientY: 60})
  assert.deepEqual(hookState.pushes, [])
})

test("a level change closes the lists a connection opened", () => {
  const hookState = dragged("stage:main")
  const list = {open: true}
  hookState.gesture = {kind: "wire", pointerId: 1, moved: true, opened: new Set([list]), over: null}
  hookState.world.dataset.level = "workflow"

  hookState.sync()

  assert.equal(hookState.gesture, null)
  assert.equal(list.open, false)
})
