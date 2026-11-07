import assert from "node:assert/strict"
import {test} from "node:test"
import hook from "./canvas_hook.js"
import * as Drag from "./drag.js"
import {screenToWorld, zoomRange} from "./geometry.js"

const element = dataset => ({
  dataset,
  attrs: new Map(),
  hasAttribute(name) { return this.attrs.has(name) },
  getAttribute(name) { return this.attrs.get(name) ?? null },
  setAttribute(name, value) { this.attrs.set(name, value) },
  removeAttribute(name) { this.attrs.delete(name) },
  querySelectorAll: () => [],
  querySelector: () => null,
  getBoundingClientRect: () => ({left: 0, top: 0, width: 800, height: 600}),
})

const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} is not ${expected}`)

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

function zoomCanvas({cards} = {}) {
  const {state, event} = background()
  if (cards) state.world.querySelectorAll = () => cards
  const output = {textContent: "100%"}
  const slider = {...element({}), id: "canvas-zoom-slider", value: "100"}
  const reset = {...element({}), id: "canvas-zoom-reset", closest: () => reset}
  state.canvas.querySelector = selector => ({"#canvas-zoom-percent": output, "#canvas-zoom-slider": slider})[selector]
  state.canvas.getBoundingClientRect = () => ({left: 30, top: 40, width: 800, height: 600})
  const slide = percent => {
    slider.value = String(percent)
    state.zoomSlider({target: slider})
  }
  const clickReset = () => state.resetView({target: reset, preventDefault() {}})
  return {state, event, output, slider, reset, slide, clickReset}
}

test("the slider sets the zoom at the canvas centre, and reset restores the view", () => {
  const {state, output, slider, slide, clickReset} = zoomCanvas()
  const center = {x: 400, y: 300}
  slide(125)
  assert.equal(state.view.zoom, 1.25)
  assert.equal(output.textContent, "125%")
  assert.equal(slider.getAttribute("aria-valuetext"), "125%")
  assert.deepEqual(screenToWorld(state.view, center), center)
  assert.equal(state.world.getAttribute("style"), "transform: translate(-100px, -75px) scale(1.25);")
  slide(100)
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
  slide(35)
  assert.equal(state.view.zoom, 0.35)
  assert.equal(output.textContent, "35%")
  clickReset()
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
  assert.equal(output.textContent, "100%")
  assert.equal(slider.value, "100")
  assert.deepEqual(state.pushes, [])
  assert.equal(state.gesture, null)
})

test("the slider ignores input events from other canvas controls", () => {
  const {state} = zoomCanvas()
  state.zoomSlider({target: {id: "node-title", value: "150"}})
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
})

test("wheel and patches keep the slider in sync; unchanged sync writes nothing", () => {
  const {state, output, slider} = zoomCanvas()
  const event = {clientX: 130, clientY: 140, deltaX: 0, deltaY: -100, ctrlKey: true, preventDefault() {}}
  state.onWheel(event)
  const view = {...state.view}
  assert.equal(view.zoom, 1.2)
  assert.equal(output.textContent, "120%")
  assert.equal(slider.value, "120")
  assert.deepEqual(screenToWorld(view, {x: 100, y: 100}), {x: 100, y: 100})
  output.textContent = "100%" // ordinary server patch
  state.sync()
  assert.deepEqual(state.view, view)
  assert.equal(output.textContent, "120%")
  for (const el of [state.world, state.canvas, state.composer, slider]) {
    el.setAttribute = el.removeAttribute = () => assert.fail("redundant attribute mutation")
  }
  Object.defineProperty(output, "textContent", {get: () => "120%", set: () => assert.fail("redundant text mutation")})
  Object.defineProperty(slider, "value", {get: () => "120", set: () => assert.fail("redundant value mutation")})
  state.sync()
})

test("level changes reset the slider and view, including its translation", () => {
  const {state, output, slider, slide} = zoomCanvas()
  slide(125)
  state.world.dataset.level = "stage:main"
  state.sync()
  assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
  assert.equal(output.textContent, "100%")
  assert.equal(slider.value, "100")
})

test("slider, reset and wheel leave every active gesture and its coordinate basis alone", () => {
  for (const kind of ["card", "wire", "pan"]) {
    const {state, output, slider, slide, clickReset} = zoomCanvas()
    const gesture = {kind, pointerId: 1}
    state.gesture = gesture
    slide(150)
    assert.equal(slider.value, "100")
    clickReset()
    state.onWheel({ctrlKey: true, deltaY: -100, preventDefault() {}})
    assert.deepEqual(state.view, {x: 0, y: 0, zoom: 1})
    assert.equal(output.textContent, "100%")
    assert.equal(state.gesture, gesture)
    assert.deepEqual(state.pushes, [])
  }
})

test("the mounted hook delegates slider input and reset clicks, and removes the listeners on destroy", () => {
  const previous = Object.fromEntries(["document", "window", "MutationObserver", "ResizeObserver"].map(key => [key, globalThis[key]]))
  const {state, slider, reset, output} = zoomCanvas()
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
  const delegated = name => listeners.find(({target, name: listened}) => target === state.canvas && listened === name)
  try {
    state.mounted()
    slider.value = "125"
    delegated("input").fn({target: slider})
    assert.equal(state.view.zoom, 1.25)
    assert.equal(output.textContent, "125%")
    delegated("click").fn({target: reset, preventDefault() {}})
    assert.equal(state.view.zoom, 1)
    state.destroyed()
    assert.deepEqual(removed, listeners)
  } finally {
    Object.assign(globalThis, previous)
  }
})

// Far wider than the 800x600 canvas, so the fit is below 1.
const wideCards = () => [
  {dataset: {node: "a", x: "0", y: "0"}, style: {}, offsetWidth: 300, offsetHeight: 200},
  {dataset: {node: "b", x: "2000", y: "0"}, style: {}, offsetWidth: 300, offsetHeight: 200},
]

// A hook through its real `mounted`, returning the observers' callbacks.
function mountedCanvas(cards) {
  const canvas = zoomCanvas({cards})
  const {state} = canvas
  const observers = []
  for (const target of [state.canvas, state.composer]) {
    target.addEventListener = target.removeEventListener = () => {}
  }
  const restore = Object.fromEntries(["document", "window", "MutationObserver", "ResizeObserver"].map(key => [key, globalThis[key]]))
  globalThis.window = {addEventListener() {}, removeEventListener() {}}
  globalThis.document = {getElementById: () => null, createElementNS: () => ({setAttribute() {}})}
  globalThis.MutationObserver = class {observe() {} disconnect() {}}
  globalThis.ResizeObserver = class {
    constructor(callback) { observers.push(callback) }
    observe() {}
    disconnect() {}
  }
  state.el = {
    closest: selector => ({"#composer": state.composer, "#stage-canvas": state.canvas, "#stage-world": state.world})[selector],
    appendChild() {},
  }
  state.handleEvent = state.draw = () => {}
  const query = state.canvas.querySelector
  state.canvas.querySelector = selector => selector === "#canvas-notice" ? {} : query(selector)
  // No view from the stubs: `mounted` has to make it.
  state.view = undefined
  state.moves = undefined
  const finish = () => Object.assign(globalThis, restore)
  return {...canvas, observers, finish}
}

test("mounting fits the cards before the first sync, and shows the fit as 100%", () => {
  const {state, output, slider, finish} = mountedCanvas(wideCards())
  try {
    state.mounted()
    assert.ok(state.fit < 1)
    assert.equal(state.view.zoom, state.fit)
    assert.ok(state.world.getAttribute("style").includes(`scale(${state.fit})`))
    assert.equal(output.textContent, "100%")
    assert.equal(slider.value, "100")
  } finally {
    finish()
  }
})

test("a canvas resize redraws without refitting", () => {
  const {state, observers, finish} = mountedCanvas(wideCards())
  try {
    state.mounted()
    state.view = {...state.view, x: state.view.x + 40}
    const view = {...state.view}
    const fit = state.fit
    state.canvas.getBoundingClientRect = () => ({left: 0, top: 0, width: 400, height: 300})
    assert.equal(observers.length, 1)
    observers[0]()
    assert.deepEqual(state.view, view)
    assert.equal(state.fit, fit)
  } finally {
    finish()
  }
})

test("Reset re-measures rather than restoring an earlier fit", () => {
  const cards = wideCards()
  const {state, output, slide, clickReset} = zoomCanvas({cards})
  clickReset()
  const before = state.fit
  assert.ok(before < 1)
  assert.equal(output.textContent, "100%")
  slide(150)
  assert.equal(output.textContent, "150%")
  cards[1].offsetWidth = 4000
  clickReset()
  assert.ok(state.fit < before)
  assert.equal(state.view.zoom, state.fit)
  assert.equal(output.textContent, "100%")
})

test("a level change fits its own cards and shows 100%", () => {
  const {state, output, slide} = zoomCanvas({cards: wideCards()})
  slide(150)
  state.world.dataset.level = "stage:main"
  state.sync()
  assert.ok(state.fit < 1)
  assert.equal(state.view.zoom, state.fit)
  assert.equal(output.textContent, "100%")
})

test("the slider's 100 is the fitted scale", () => {
  const {state, output, slide, clickReset} = zoomCanvas({cards: wideCards()})
  clickReset()
  const fit = state.fit
  slide(150)
  slide(100)
  close(state.view.zoom, fit)
  assert.equal(output.textContent, "100%")
})

// A fit that integer card sizes can't produce exactly.
function fittedAt(fit) {
  const canvas = zoomCanvas()
  canvas.state.fit = fit
  canvas.state.view = {x: 0, y: 0, zoom: fit}
  return canvas
}

test("the slider's max is written before its value, which the browser would clamp", () => {
  const {state, slider, output} = fittedAt(0.37)
  const writes = []
  const setAttribute = slider.setAttribute
  slider.setAttribute = function (name, value) {
    writes.push(name)
    setAttribute.call(this, name, value)
  }
  let value = "100"
  Object.defineProperty(slider, "value", {
    get: () => value,
    set(next) {
      writes.push("value")
      value = next
    },
  })
  state.view = {...state.view, zoom: 0.37 * 2.75}
  state.sync()
  assert.equal(slider.getAttribute("max"), "275")
  assert.equal(value, "275")
  assert.ok(writes.indexOf("max") < writes.indexOf("value"), writes.join())
  assert.equal(output.textContent, "275%")
})

test("the slider is relative to the fit: its top reaches real size, and 25 is a quarter of the fit", () => {
  const {state, output, slide} = fittedAt(0.37)
  slide(275)
  assert.ok(state.view.zoom >= 1)
  assert.equal(output.textContent, "275%")
  slide(25)
  close(state.view.zoom, 0.0925)
  assert.equal(output.textContent, "25%")
})

test("the wheel lands on a percent step of the fit and stops at the fit's range", () => {
  const {state, output} = fittedAt(0.37)
  const wheelBy = deltaY => state.onWheel({clientX: 130, clientY: 140, deltaX: 0, deltaY, ctrlKey: true, preventDefault() {}})
  wheelBy(-100)
  const percent = (state.view.zoom / 0.37) * 100
  close(percent, Math.round(percent / 5) * 5)
  assert.equal(output.textContent, `${Math.round(percent)}%`)
  for (let i = 0; i < 50; i++) wheelBy(-100)
  close(state.view.zoom, zoomRange(0.37).max)
  assert.equal(output.textContent, "275%")
  for (let i = 0; i < 100; i++) wheelBy(100)
  close(state.view.zoom, zoomRange(0.37).min)
  assert.equal(output.textContent, "25%")
})

test("an unchanged sync at a fit writes nothing to the slider", () => {
  const {state, slider, output} = fittedAt(0.37)
  state.sync()
  for (const el of [state.world, state.canvas, state.composer, slider]) {
    el.setAttribute = el.removeAttribute = () => assert.fail("redundant attribute mutation")
  }
  Object.defineProperty(output, "textContent", {get: () => "100%", set: () => assert.fail("redundant text mutation")})
  Object.defineProperty(slider, "value", {get: () => "100", set: () => assert.fail("redundant value mutation")})
  state.sync()
})

test("a card dragged at a fit moves by the screen delta over the true scale", () => {
  const cards = wideCards()
  const {state, event, clickReset} = zoomCanvas({cards})
  clickReset()
  const scale = state.view.zoom
  const view = {...state.view}
  const target = {closest: query => query === "article[data-node]" ? cards[0] : null}
  state.pointerDown({...event, target, clientX: 100, clientY: 100})
  state.pointerMove({...event, target, clientX: 150, clientY: 130})
  state.pointerUp({...event, target, clientX: 150, clientY: 130})
  assert.deepEqual(state.pushes, [{
    name: "node_moved",
    payload: {node: "a", x: Math.round(50 / scale), y: Math.round(30 / scale), level: "workflow"},
  }])
  assert.deepEqual(state.view, view)
})

// An After connection held over one card, as the browser's hit test would answer.
function overCard(card) {
  const state = Object.create(hook)
  state.canvas = {contains: () => true}
  state.hit = () => ({closest: query => query === "article[data-node]" ? card : null})
  return state.dropTarget({after: true, source: "other", pointer: {x: 0, y: 0}})
}

test("an After connection takes no source node as its target, and doesn't throw on it", () => {
  // A source node has no after-in socket, so reading one would throw.
  assert.equal(overCard({dataset: {node: "prompt", sourceNode: ""}, querySelector: () => null}), null)
})

test("an After connection over a runner card targets its after-in socket", () => {
  const socket = {dataset: {socket: "after-in:a"}}
  const card = {dataset: {node: "a"}, querySelector: () => socket}
  assert.deepEqual(overCard(card), {el: card, socket: "after-in:a"})
})

test("a Reset during a gesture leaves a fitted view and its fit alone", () => {
  const cards = wideCards()
  const {state, output, slide, clickReset} = zoomCanvas({cards})
  clickReset()
  slide(150)
  const view = {...state.view}
  const fit = state.fit
  state.gesture = {kind: "pan", pointerId: 1}
  cards[1].offsetWidth = 4000
  clickReset()
  assert.deepEqual(state.view, view)
  assert.equal(state.fit, fit)
  assert.equal(output.textContent, "150%")
})

test("read-only: a press on a card or a socket starts no gesture, and the background still pans", () => {
  const card = {dataset: {node: "a"}}
  const socket = {dataset: {socket: "out:a", source: "a"}}
  for (const [name, closest] of [
    ["card", query => query === "article[data-node]" ? card : null],
    ["socket", query => query === "[data-source], [data-after-source]" ? socket : null],
  ]) {
    const {state, event} = background()
    state.canvas.dataset.readOnly = ""
    state.pointerDown({...event, target: {closest}, preventDefault() {}})
    assert.equal(state.gesture, null, name)
    assert.deepEqual(state.pushes, [], name)
  }

  const {state, event} = background()
  state.canvas.dataset.readOnly = ""
  state.pointerDown(event)
  assert.equal(state.gesture?.kind, "pan")
})

test("read-only: the undo key pushes nothing", () => {
  const previous = globalThis.document
  globalThis.document = {getElementById: () => null}
  try {
    const {state} = background()
    state.canvas.dataset.readOnly = ""
    let prevented = false
    state.keyDown({key: "z", metaKey: true, ctrlKey: false, shiftKey: false, target: {tagName: "DIV"}, preventDefault() { prevented = true }})
    assert.deepEqual(state.pushes, [])
    assert.equal(prevented, false)

    delete state.canvas.dataset.readOnly
    state.keyDown({key: "z", metaKey: true, ctrlKey: false, shiftKey: false, target: {tagName: "DIV"}, preventDefault() {}})
    assert.deepEqual(state.pushes, [{name: "undo", payload: {}}])
  } finally {
    globalThis.document = previous
  }
})
