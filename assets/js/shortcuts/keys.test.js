import assert from "node:assert/strict"
import {test} from "node:test"
import {decide, modalOpen, typing} from "./keys.js"

const base = {
  key: "g", altKey: false, metaKey: false, ctrlKey: false, repeat: false, isComposing: false,
  typing: false, modal: false, pending: null, prefixes: ["g"], hintsKey: "?",
}
const at = overrides => decide({...base, ...overrides})

test("a prefix arms, and the next key makes the combo", () => {
  assert.deepEqual(at({key: "g"}), {type: "arm", prefix: "g"})
  assert.deepEqual(at({key: "w", pending: "g"}), {type: "go", combo: "g w"})
})

test("typing, modifiers, repeat and IME composition are ignored", () => {
  for (const overrides of [{typing: true}, {metaKey: true}, {ctrlKey: true}, {altKey: true}, {repeat: true}, {isComposing: true}]) {
    assert.deepEqual(at(overrides), {type: "ignore"}, JSON.stringify(overrides))
    assert.deepEqual(at({...overrides, key: "w", pending: "g"}), {type: "ignore"}, JSON.stringify(overrides))
  }
})

test("a modal clears a pending prefix and otherwise ignores keys", () => {
  assert.deepEqual(at({modal: true, key: "w", pending: "g"}), {type: "clear"})
  assert.deepEqual(at({modal: true, key: "g"}), {type: "ignore"})
  assert.deepEqual(at({modal: true, key: "?"}), {type: "ignore"})
})

test("the hints key toggles hints and Escape hides them, even when pending or under a modal", () => {
  assert.deepEqual(at({key: "?"}), {type: "hints"})
  assert.deepEqual(at({key: "Escape"}), {type: "hide"})
  assert.deepEqual(at({key: "Escape", pending: "g"}), {type: "hide"})
  assert.deepEqual(at({key: "Escape", modal: true}), {type: "hide"})
})

test("any other key is ignored", () => {
  assert.deepEqual(at({key: "x"}), {type: "ignore"})
})

test("typing means an editable target or focus in a non-drawer dialog", () => {
  assert.equal(typing({tagName: "INPUT"}), true)
  assert.equal(typing({tagName: "INPUT", type: "range"}), false)
  assert.equal(typing(null), false)
  // Inside the overlay drawer: only a selector without the drawer exclusion would match.
  const inDrawer = {tagName: "A", closest: selector => selector.includes(":not(#dashboard-drawer)") ? null : {}}
  assert.equal(typing(inDrawer), false)
  const inPopover = {tagName: "BUTTON", closest: selector => selector === "[role='dialog']:not(#dashboard-drawer)" ? {} : null}
  assert.equal(typing(inPopover), true)
})

test("a modal is any aria-modal element except the overlay drawer", () => {
  const drawerOnly = {querySelector: selector => selector === "[aria-modal='true']" ? {} : null}
  assert.equal(modalOpen(drawerOnly), false)
  const dialog = {querySelector: selector => selector === "[aria-modal='true']:not(#dashboard-drawer)" ? {} : null}
  assert.equal(modalOpen(dialog), true)
})
