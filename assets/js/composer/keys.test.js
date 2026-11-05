import assert from "node:assert/strict"
import {test} from "node:test"
import {escapeAction, isEditable, isUndo} from "./keys.js"

test("text entry is editable and a button isn't", () => {
  for (const tagName of ["INPUT", "TEXTAREA", "SELECT"]) assert.equal(isEditable({tagName}), true)
  assert.equal(isEditable({tagName: "DIV", isContentEditable: true}), true)
  assert.equal(isEditable({tagName: "BUTTON"}), false)
  assert.equal(isEditable(null), false)
})

test("Cmd or Ctrl+Z is undo, and with Shift it isn't", () => {
  assert.equal(isUndo({metaKey: true, key: "z"}), true)
  assert.equal(isUndo({ctrlKey: true, key: "Z"}), true)
  assert.equal(isUndo({metaKey: true, shiftKey: true, key: "z"}), false)
  assert.equal(isUndo({key: "z"}), false)
})

test("Escape closes the picker, then the confirmation, the gesture, the selection", () => {
  const all = {picker: true, confirmation: true, gesture: true, selection: true, editable: false}
  assert.equal(escapeAction(all), "picker")
  assert.equal(escapeAction({...all, picker: false}), "confirmation")
  assert.equal(escapeAction({...all, picker: false, confirmation: false}), "gesture")
  assert.equal(escapeAction({...all, picker: false, confirmation: false, gesture: false}), "selection")
  assert.equal(escapeAction({}), null)
})

test("Escape while typing keeps the selection, but still cancels a gesture", () => {
  assert.equal(escapeAction({selection: true, editable: true}), null)
  assert.equal(escapeAction({gesture: true, selection: true, editable: true}), "gesture")
})
