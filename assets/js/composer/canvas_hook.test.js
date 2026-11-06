import assert from "node:assert/strict"
import {test} from "node:test"
import hook from "./canvas_hook.js"
import * as Drag from "./drag.js"
import {screenToWorld} from "./geometry.js"

const element = dataset => ({
  dataset,
  attrs: new Map(),
  hasAttribute(name) { return this.attrs.has(name) },
  getAttribute(name) { return this.attrs.get(name) ?? null },
  setAttribute(name, value) { this.attrs.set(name, value) },
  removeAttribute(name) { this.attrs.delete(name) },
  querySelectorAll: () => [],
  querySelector: () => null,
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

function background() {
  const state = dragged("workflow")
  state.gesture = null
  state.moves.clear()
  state.composer.setPointerCapture = () => {}
  state.canvas.contains = () => true
  const target = {closest: () => null}
  return {state, event: {target, button: 0, pointerId: 2, clientX: 10, clientY: 10, buttons: 1}}
}

test("only an unmoved completed blank gesture deselects", () => {
  const {state, event} = background()
  state.pointerDown(event)
  state.pointerUp(event)
  assert.deepEqual(state.pushes, [{name: "deselect_node", payload: {}}])
})

test("moved, canceled, lost-capture and mismatched pointer gestures do not deselect", () => {
  for (const finish of [
    (state, event) => state.pointerMove({...event, clientX: 30}),
    state => state.cancelGesture(),
    state => state.captureLost({pointerId: 2}),
    (state, event) => state.pointerUp({...event, pointerId: 3}),
  ]) {
    const {state, event} = background()
    state.pointerDown(event)
    finish(state, event)
    if (state.gesture?.moved) state.pointerUp({...event, clientX: 30})
    assert.deepEqual(state.pushes, [])
  }
})

test("a release past the movement threshold cannot dismiss without a move event", () => {
  const {state, event} = background()
  state.pointerDown(event)
  state.pointerUp({...event, clientX: 30})
  assert.deepEqual(state.pushes, [])
})

test("card controls, sockets, forms, toolbar and tools never begin a background pan", () => {
  for (const selector of ["button", "input", "select", "textarea", "[data-socket]", "[data-canvas-control]"]) {
    const {state, event} = background()
    event.target.closest = query => query.includes(selector) ? {} : null
    state.pointerDown(event)
    assert.equal(state.gesture, null, selector)
    state.pointerUp(event)
    assert.deepEqual(state.pushes, [])
  }
  const {state, event} = background()
  const card = {dataset: {node: "a"}}
  event.target.closest = query => query === "article[data-node]" ? card : query.includes("input") ? {} : null
  state.pointerDown(event)
  assert.equal(state.gesture, null)
})

test("issue focus waits for a mounted target and falls back when Tools removes its trigger", () => {
  const previous = globalThis.document
  const state = Object.create(hook)
  const focused = []
  const nodes = new Map()
  const body = {}
  globalThis.document = {body, activeElement: body, getElementById: id => nodes.get(id)}
  const target = id => ({id, focus() {focused.push(id); document.activeElement = this}})
  try {
    state.pendingFocus = "field-a-name"
    state.syncFocus()
    assert.equal(state.pendingFocus, "field-a-name")
    nodes.set("field-a-name", target("field-a-name"))
    state.syncFocus()
    assert.equal(state.pendingFocus, null)
    assert.deepEqual(focused, ["field-a-name"])
    nodes.set("composer-tools", {})
    nodes.set("close-tools", target("close-tools"))
    nodes.set("open-tools", target("open-tools"))
    state.syncFocus()
    nodes.delete("composer-tools")
    nodes.delete("field-a-name")
    document.activeElement = body
    state.syncFocus()
    assert.equal(focused.at(-1), "open-tools")
  } finally {
    globalThis.document = previous
  }
})

test("a confirmation Escape leaves both covered pickers, Tools and selection alone", () => {
  const previous = globalThis.document
  const clicked = []
  const state = Object.create(hook)
  const nodes = new Map(["confirm-replace-literal", "connect-close", "deselect-node", "composer-tools", "close-tools"].map(id => [id, {click: () => clicked.push(id)}]))
  globalThis.document = {getElementById: id => nodes.get(id)}
  try {
    state.escape({target: {tagName: "BUTTON"}})
    assert.deepEqual(clicked, [])
    nodes.set("close-picker", {click: () => clicked.push("close-picker")})
    state.escape({target: {tagName: "BUTTON"}})
    assert.deepEqual(clicked, [])

    // Once uncovered, each subsequent key closes just the first picker.
    nodes.delete("confirm-replace-literal")
    state.escape({target: {tagName: "BUTTON"}})
    assert.deepEqual(clicked, ["connect-close"])
    nodes.delete("connect-close")
    state.escape({target: {tagName: "BUTTON"}})
    assert.deepEqual(clicked, ["connect-close", "close-picker"])
  } finally {
    globalThis.document = previous
  }
})

function zoomCanvas() {
  const {state, event} = background()
  const output = {textContent: "100%"}
  const controls = new Map(["in", "out", "reset"].map(action => [action, {
    ...element({zoomAction: action}),
    closest: () => controls.get(action),
  }]))
  state.canvas.querySelector = selector => selector === "#canvas-zoom-percent" ? output :
    controls.get(selector.match(/data-zoom-action="(.*?)"/)?.[1])
  state.canvas.getBoundingClientRect = () => ({left: 30, top: 40, width: 800, height: 600})
  const click = action => state.zoomControl({target: controls.get(action), preventDefault() {}})
  return {state, event, output, controls, click}
}

test("toolbar dispatch shares the bounded viewport, center anchor, percentage and disabled state", () => {
  const {state, output, controls, click} = zoomCanvas()
  const center = {x: 400, y: 300}
  click("in")
  assert.equal(state.view.zoom, 1.25)
  assert.equal(output.textContent, "125%")
  assert.deepEqual(screenToWorld(state.view, center), center)
  assert.equal(state.world.getAttribute("style"), "transform: translate(-100px, -75px) scale(1.25);")
  click("out")
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
  for (let i = 0; i < 20; i++) click("in")
  assert.equal(state.view.zoom, 2)
  assert.equal(output.textContent, "200%")
  assert.equal(controls.get("in").hasAttribute("disabled"), true)
  assert.equal(controls.get("out").hasAttribute("disabled"), false)
  for (let i = 0; i < 30; i++) click("out")
  assert.equal(state.view.zoom, 0.25)
  assert.equal(output.textContent, "25%")
  assert.equal(controls.get("out").hasAttribute("disabled"), true)
  assert.equal(controls.get("in").hasAttribute("disabled"), false)
  click("reset")
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
  assert.equal(output.textContent, "100%")
  assert.deepEqual(state.pushes, [])
  assert.equal(state.gesture, null)
})

test("wheel and patches keep toolbar state in sync; unchanged sync writes nothing", () => {
  const {state, output, controls} = zoomCanvas()
  const event = {clientX: 130, clientY: 140, deltaX: 0, deltaY: -100, ctrlKey: true, preventDefault() {}}
  state.onWheel(event)
  const view = {...state.view}
  assert.equal(output.textContent, `${Math.round(view.zoom * 100)}%`)
  assert.deepEqual(screenToWorld(view, {x: 100, y: 100}), {x: 100, y: 100})
  output.textContent = "100%" // ordinary server patch
  state.sync()
  assert.deepEqual(state.view, view)
  assert.equal(output.textContent, `${Math.round(view.zoom * 100)}%`)
  for (const el of [state.world, state.canvas, state.composer, ...controls.values()]) {
    el.setAttribute = el.removeAttribute = () => assert.fail("redundant attribute mutation")
  }
  Object.defineProperty(output, "textContent", {get: () => `${Math.round(view.zoom * 100)}%`, set: () => assert.fail("redundant text mutation")})
  state.sync()
})

test("level changes reset the toolbar and view, including its translation", () => {
  const {state, output, click} = zoomCanvas()
  click("in")
  state.world.dataset.level = "stage:main"
  state.sync()
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
  assert.equal(output.textContent, "100%")
})

test("toolbar and wheel leave every active gesture and its coordinate basis alone", () => {
  for (const kind of ["card", "wire", "pan"]) {
    const {state, output, click} = zoomCanvas()
    const gesture = {kind, pointerId: 1}
    state.gesture = gesture
    for (const action of ["in", "out", "reset"]) click(action)
    state.onWheel({ctrlKey: true, deltaY: -100, preventDefault() {}})
    assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
    assert.equal(output.textContent, "100%")
    assert.equal(state.gesture, gesture)
    assert.deepEqual(state.pushes, [])
  }
})

test("the mounted hook delegates toolbar clicks and removes the listener on destroy", () => {
  const previous = Object.fromEntries(["document", "window", "MutationObserver", "ResizeObserver"].map(key => [key, globalThis[key]]))
  const {state, controls, output} = zoomCanvas()
  const listeners = []
  const removed = []
  for (const target of [state.canvas, state.composer]) {
    target.addEventListener = (name, fn, options) => listeners.push({target, name, fn, options})
    target.removeEventListener = (name, fn, options) => removed.push({target, name, fn, options})
  }
  globalThis.window = {addEventListener() {}, removeEventListener() {}}
  globalThis.document = {getElementById: () => null, createElementNS: () => ({setAttribute() {}})}
  globalThis.MutationObserver = globalThis.ResizeObserver = class {observe() {} disconnect() {}}
  state.el = {
    closest: selector => ({"#composer": state.composer, "#stage-canvas": state.canvas, "#stage-world": state.world})[selector],
    appendChild() {},
  }
  state.handleEvent = state.draw = () => {}
  state.canvas.querySelector = (original => selector => selector === "#canvas-notice" ? {} : original(selector))(state.canvas.querySelector)
  try {
    state.mounted()
    const delegated = listeners.find(({target, name}) => target === state.canvas && name === "click")
    assert.ok(delegated)
    delegated.fn({target: controls.get("in"), preventDefault() {}})
    assert.equal(state.view.zoom, 1.25)
    assert.equal(output.textContent, "125%")
    state.destroyed()
    assert.deepEqual(removed, listeners)
  } finally {
    Object.assign(globalThis, previous)
  }
})
