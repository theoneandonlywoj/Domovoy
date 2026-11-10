import assert from "node:assert/strict"
import {test} from "node:test"
import hook from "./hook.js"

const NON_DRAWER_MODAL = "[aria-modal='true']:not(#dashboard-drawer)"

// A fake window, document and location on globalThis; `modal` picks which modal selector matches.
function setup(t, {pathname = "/dashboard/jobs", modal = null} = {}) {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const previous = {window: globalThis.window, document: globalThis.document, location: globalThis.location}
  const added = []
  const removed = []
  const link = {dataset: {shortcut: "g w"}, href: "http://localhost/dashboard/workflows", clicks: 0, click() { this.clicks++ }}
  globalThis.window = {
    addEventListener: (name, fn, options) => added.push({name, fn, options}),
    removeEventListener: (name, fn, options) => removed.push({name, fn, options}),
  }
  globalThis.document = {
    documentElement: {dataset: {}},
    querySelectorAll: selector => selector === "[data-shortcut]" ? [link] : [],
    querySelector: selector => (modal === "drawer" ? selector === "[aria-modal='true']" : modal === "dialog" && selector === NON_DRAWER_MODAL) ? {} : null,
  }
  globalThis.location = {pathname}
  const state = Object.assign(Object.create(hook), {el: {dataset: {prefixes: "g", hintsKey: "?"}}})
  let prevented = 0
  const press = (key, target = {tagName: "BODY", closest: () => null}) => state.keyDown({key, target, preventDefault() { prevented++ }})
  return {
    state, link, added, removed, press,
    prevented: () => prevented,
    root: globalThis.document.documentElement,
    restore: () => Object.assign(globalThis, previous),
  }
}

// Runs `body` with the fakes installed and the hook mounted, and restores the globals after.
const withHook = (t, options, body) => {
  const env = setup(t, options)
  try {
    env.state.mounted()
    body(env)
  } finally {
    env.restore()
  }
}

test("mounted adds one capture keydown listener and destroyed removes the same one", t => {
  withHook(t, {}, ({state, added, removed}) => {
    assert.equal(added.length, 1)
    assert.equal(added[0].name, "keydown")
    assert.deepEqual(added[0].options, {capture: true})
    state.destroyed()
    assert.deepEqual(removed, added)
  })
})

test("g then w clicks the bound link once", t => {
  withHook(t, {}, ({link, press, prevented}) => {
    press("g")
    press("w")
    assert.equal(link.clicks, 1)
    assert.equal(prevented(), 2)
  })
})

test("the prefix lasts until just before 1000 ms", t => {
  withHook(t, {}, ({link, press}) => {
    press("g")
    t.mock.timers.tick(999)
    press("w")
    assert.equal(link.clicks, 1)
  })
})

test("the prefix expires at 1000 ms", t => {
  withHook(t, {}, ({link, press, root}) => {
    press("g")
    assert.equal(root.dataset.hintsPrefix, "g")
    t.mock.timers.tick(1000)
    assert.equal(root.dataset.hintsPrefix, undefined)
    press("w")
    assert.equal(link.clicks, 0)
  })
})

test("an unbound second key clicks nothing, is not prevented and clears the prefix", t => {
  withHook(t, {}, ({link, press, prevented, root}) => {
    press("g")
    press("x")
    assert.equal(link.clicks, 0)
    assert.equal(prevented(), 1)
    assert.equal("hintsPrefix" in root.dataset, false)
  })
})

test("Escape clears a pending prefix", t => {
  withHook(t, {}, ({link, press, root}) => {
    press("g")
    press("Escape")
    assert.equal("hintsPrefix" in root.dataset, false)
    press("w")
    assert.equal(link.clicks, 0)
  })
})

test("keys typed into an input do nothing", t => {
  withHook(t, {}, ({link, press, prevented}) => {
    const input = {tagName: "INPUT", closest: () => null}
    press("g", input)
    press("w", input)
    assert.equal(link.clicks, 0)
    assert.equal(prevented(), 0)
  })
})

test("going to the current page does nothing", t => {
  withHook(t, {pathname: "/dashboard/workflows"}, ({link, press}) => {
    press("g")
    press("w")
    assert.equal(link.clicks, 0)
  })
})

test("a modal dialog blocks the keys", t => {
  withHook(t, {modal: "dialog"}, ({link, press}) => {
    press("g")
    press("w")
    assert.equal(link.clicks, 0)
  })
})

test("the open overlay drawer does not block its own keys", t => {
  withHook(t, {modal: "drawer"}, ({link, press}) => {
    press("g")
    press("w")
    assert.equal(link.clicks, 1)
  })
})

test("? toggles hints and Escape hides them without preventDefault", t => {
  withHook(t, {}, ({press, prevented, root}) => {
    press("?")
    assert.equal(root.dataset.hints, "on")
    press("?")
    assert.equal("hints" in root.dataset, false)
    press("?")
    assert.equal(prevented(), 3)
    press("Escape")
    assert.equal("hints" in root.dataset, false)
    assert.equal(prevented(), 3)
  })
})

test("destroyed clears a pending prefix and its timer", t => {
  withHook(t, {}, ({state, press, root}) => {
    press("g")
    state.destroyed()
    assert.equal("hintsPrefix" in root.dataset, false)
    assert.doesNotThrow(() => t.mock.timers.tick(1000))
    assert.equal(state.pending, null)
  })
})
