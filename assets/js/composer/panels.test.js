import assert from "node:assert/strict"
import {test} from "node:test"
import {CANVAS_MIN, PIN_GAP, PIN_MAX, PIN_MIN, canPin, clampWidth} from "./panels.js"

test("pinning needs 600 px of canvas left beside the dock and its gap", () => {
  assert.equal(CANVAS_MIN, 600)
  assert.equal(PIN_GAP, 12)
  assert.equal(canPin(1000, 440), false)
  assert.equal(canPin(1416, 440), true)
  assert.equal(canPin(992, 440), false)
  assert.equal(canPin(992, 384), false)
  assert.equal(canPin(995, 384), false)
  assert.equal(canPin(996, 384), true)
})

test("the dock width stays between 320 and 440 px", () => {
  assert.equal(clampWidth(200), PIN_MIN)
  assert.equal(clampWidth(200), 320)
  assert.equal(clampWidth(600), PIN_MAX)
  assert.equal(clampWidth(600), 440)
  assert.equal(clampWidth(400), 400)
})
