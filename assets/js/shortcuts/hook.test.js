import assert from "node:assert/strict"
import {test} from "node:test"
import hook from "./hook.js"

const NON_DRAWER_MODAL = "[aria-modal='true']:not(#dashboard-drawer)"

const DRAWER_OPEN = "#dashboard-drawer[aria-modal='true']"
const BODY = {tagName: "BODY", closest: () => null}

const makeLink = ({shortcut, phxLink, href}) =>
  ({dataset: {shortcut, phxLink}, href, clicks: 0, click() { this.clicks++ }})

// A fake window, document and location on globalThis; `modal` picks which modal selector matches,
// `drawerOpen` opens the overlay drawer (whose links are the `g ` ones), `field` adds a focus target.
function setup(t, {pathname = "/dashboard/jobs", search = "", modal = null, drawerOpen = false, links, field = false} = {}) {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const previous = {window: globalThis.window, document: globalThis.document, location: globalThis.location}
  const added = []
  const removed = []
  links = links || [makeLink({shortcut: "g w", phxLink: "redirect", href: "http://localhost/dashboard/workflows"})]
  const [link] = links
  let input = null
  let fieldEl = null
  if (field) {
    input = {focused: 0, focus() { this.focused++ }, blur() { this.blurred = (this.blurred || 0) + 1 }, closest: s => s === "[data-shortcut-focus]" ? fieldEl : null}
    fieldEl = {dataset: {shortcut: "/"}, hasAttribute: n => n === "data-shortcut-focus", contains: el => el === input, querySelector: () => input}
  }
  const before = {isConnected: true, focused: 0, focus() { this.focused++ }, closest: () => null}
  const drawer = {contains: el => Boolean(el?.dataset?.shortcut?.startsWith("g "))}
  globalThis.window = {
    addEventListener: (name, fn, options) => added.push({name, fn, options}),
    removeEventListener: (name, fn, options) => removed.push({name, fn, options}),
  }
  globalThis.document = {
    documentElement: {dataset: {}},
    body: {},
    activeElement: before,
    querySelectorAll: selector => selector === "[data-shortcut]" ? [...links, fieldEl].filter(Boolean) : [],
    querySelector: selector => {
      if (drawerOpen && selector === DRAWER_OPEN) return drawer
      return (modal === "drawer" ? selector === "[aria-modal='true']" : modal === "dialog" && selector === NON_DRAWER_MODAL) ? {} : null
    },
  }
  globalThis.location = {pathname, search, href: "http://localhost" + pathname + search}
  const state = Object.assign(Object.create(hook), {el: {dataset: {prefixes: "g f", hintsKey: "?", focusKey: "/"}}})
  let prevented = 0
  const press = (key, target = BODY, extra = {}) => state.keyDown({key, target, ...extra, preventDefault() { prevented++ }})
  const focusIn = target => added.find(l => l.name === "focusin").fn({target})
  return {
    state, link, links, field: fieldEl, input, before, added, removed, press, focusIn,
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

test("mounted adds a capture keydown and a focusin listener and destroyed removes the same ones", t => {
  withHook(t, {}, ({state, added, removed}) => {
    assert.equal(added.length, 2)
    assert.equal(added[0].name, "keydown")
    assert.deepEqual(added[0].options, {capture: true})
    assert.equal(added[1].name, "focusin")
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

const chip = (shortcut, href) => makeLink({shortcut, phxLink: "patch", href})
const RUNNING = "http://localhost/dashboard/jobs?status=running"

test("(a) f 2 clicks a patch chip whose query differs on the same path", t => {
  withHook(t, {links: [chip("f 2", RUNNING)]}, ({link, press}) => {
    press("f")
    press("2")
    assert.equal(link.clicks, 1)
  })
})

test("(b) a patch chip to the current URL is not clicked", t => {
  withHook(t, {search: "?status=running", links: [chip("f 2", RUNNING)]}, ({link, press}) => {
    press("f")
    press("2")
    assert.equal(link.clicks, 0)
  })
})

test("(c) g j on a filtered panel keeps the filters", t => {
  const links = [makeLink({shortcut: "g j", phxLink: "redirect", href: "http://localhost/dashboard/jobs"})]
  withHook(t, {search: "?q=borg", links}, ({link, press}) => {
    press("g")
    press("j")
    assert.equal(link.clicks, 0)
  })
})

test("(d) f 1 patches back to All from a status filter", t => {
  withHook(t, {search: "?status=failed", links: [chip("f 1", "http://localhost/dashboard/jobs")]}, ({link, press}) => {
    press("f")
    press("1")
    assert.equal(link.clicks, 1)
  })
})

test("(e) / focuses the field's input without clicking", t => {
  withHook(t, {field: true}, ({link, input, press, prevented}) => {
    press("/")
    assert.equal(input.focused, 1)
    assert.equal(prevented(), 1)
    assert.equal(link.clicks, 0)
  })
})

test("(f) Cmd+K focuses the field", t => {
  withHook(t, {field: true}, ({input, press, prevented}) => {
    press("k", BODY, {metaKey: true})
    assert.equal(input.focused, 1)
    assert.equal(prevented(), 1)
  })
})

test("(f) Cmd+K without a field keeps the browser default", t => {
  withHook(t, {}, ({link, press, prevented}) => {
    press("k", BODY, {metaKey: true})
    assert.equal(prevented(), 0)
    assert.equal(link.clicks, 0)
  })
})

test("(g) / does nothing while the overlay drawer is open", t => {
  withHook(t, {field: true, drawerOpen: true}, ({input, press, prevented}) => {
    press("/")
    assert.equal(input.focused, 0)
    assert.equal(prevented(), 0)
  })
})

test("(h) Esc in the field blurs it, returns focus and hides hints", t => {
  withHook(t, {field: true}, ({input, before, press, prevented, root}) => {
    press("/")
    root.dataset.hints = "on"
    press("Escape", input)
    assert.equal(input.blurred, 1)
    assert.equal(before.focused, 1)
    assert.equal(prevented(), 2)
    assert.equal("hints" in root.dataset, false)
  })
})

test("(j) focus leaving the field forgets the return target", t => {
  withHook(t, {field: true}, ({input, before, press, focusIn}) => {
    press("/")
    focusIn({closest: () => null})
    press("Escape", input)
    assert.equal(input.blurred, 1)
    assert.equal(before.focused, 0)
  })
})

test("(k) Esc during IME composition in the field does nothing", t => {
  withHook(t, {field: true}, ({input, press, prevented}) => {
    press("Escape", input, {isComposing: true})
    assert.equal(input.blurred, undefined)
    assert.equal(prevented(), 0)
  })
})

test("(l) Esc in another input is not prevented", t => {
  withHook(t, {field: true}, ({press, prevented}) => {
    press("Escape", {tagName: "INPUT", closest: () => null})
    assert.equal(prevented(), 0)
  })
})

test("(m) with the overlay drawer open a chip behind it is not clicked, its own links are", t => {
  const links = [chip("f 2", RUNNING), makeLink({shortcut: "g w", phxLink: "redirect", href: "http://localhost/dashboard/workflows"})]
  withHook(t, {drawerOpen: true, links}, ({links: [f2, gw], press}) => {
    press("f")
    press("2")
    assert.equal(f2.clicks, 0)
    press("g")
    press("w")
    assert.equal(gw.clicks, 1)
  })
})

test("(n) Cmd+K while typing does not take focus", t => {
  withHook(t, {field: true}, ({input, press, prevented}) => {
    press("k", {tagName: "INPUT", closest: () => null}, {metaKey: true})
    assert.equal(input.focused, 0)
    assert.equal(prevented(), 0)
  })
})
