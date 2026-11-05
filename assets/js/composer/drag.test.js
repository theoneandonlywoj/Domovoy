import assert from "node:assert/strict"
import {test} from "node:test"
import {awaited, buttonUp, cancel, move, pastThreshold, position, release, settle, start} from "./drag.js"

const server = {x: 100, y: 200}
const begin = (zoom = 1) => start({from: server, pointer: {x: 10, y: 10}, zoom, token: 1})
const dragged = () => move(begin(), {x: 60, y: 30})

test("moving sends nothing, and release gives one command at the shown position", () => {
  const state = dragged()
  assert.deepEqual(position(state, server), {x: 150, y: 220})

  const released = release(state, true)
  assert.deepEqual(released.command, {x: 150, y: 220})
  assert.equal(released.state.phase, "pending")
  assert.equal(released.lost, false)
})

test("movement converts through the zoom", () => {
  assert.deepEqual(position(move(begin(0.5), {x: 60, y: 30}), server), {x: 200, y: 240})
})

test("a press with no real movement is a click: no command and no notice", () => {
  const state = move(begin(), {x: 12, y: 10})
  assert.equal(state.moved, false)
  assert.deepEqual(position(state, server), server)
  assert.deepEqual(release(state, true), {state: null, command: null, lost: false})
})

test("a patch during a drag or a pending move keeps the position", () => {
  const state = dragged()
  assert.deepEqual(position(state, {x: 1, y: 2}), {x: 150, y: 220})
  assert.deepEqual(position(release(state, true).state, {x: 3, y: 4}), {x: 150, y: 220})
})

test("release while disconnected sends nothing, goes back and says so", () => {
  const {state, command, lost} = release(dragged(), false)
  assert.equal(command, null)
  assert.equal(lost, true)
  assert.deepEqual(position(state, server), server)
})

test("ok and noop end the move without a notice", () => {
  const pending = release(dragged(), true).state
  for (const status of ["ok", "noop"]) assert.deepEqual(settle(pending, 1, status), {state: null, lost: false})
})

test("any other status reverts with a notice, unknown or missing included", () => {
  const pending = release(dragged(), true).state
  for (const status of ["conflict", "rejected", "failed", "disconnected", "surprise", undefined]) {
    const {state, lost} = settle(pending, 1, status)
    assert.equal(lost, true, String(status))
    assert.deepEqual(position(state, server), server)
  }
})

test("a disconnect settles a pending move, and its late answer then does nothing", () => {
  const pending = release(dragged(), true).state
  const {state} = settle(pending, 1, "disconnected")
  assert.deepEqual(settle(state, 1, "ok"), {state: null, lost: false})
})

test("a late answer leaves a newer drag of the same card alone", () => {
  const newer = start({from: server, pointer: {x: 0, y: 0}, zoom: 1, token: 2})
  assert.deepEqual(settle(newer, 1, "conflict"), {state: newer, lost: false})

  const newerPending = release(move(newer, {x: 50, y: 0}), true).state
  assert.deepEqual(settle(newerPending, 1, "ok"), {state: newerPending, lost: false})
})

test("a drag still under way is not settled", () => {
  const state = dragged()
  assert.deepEqual(settle(state, 1, "ok"), {state, lost: false})
})

const pendingMove = () => release(dragged(), true).state
const pressPending = pending =>
  start({from: position(pending, server), pointer: {x: 0, y: 0}, zoom: 1, token: 2, prior: pending})

for (const [how, end] of [
  ["no-move release", state => release(state, true)],
  ["cancel", cancel],
]) {
  test(`a ${how} of a press on a pending card keeps the pending move`, () => {
    const pending = pendingMove()
    const {state, lost} = end(pressPending(pending))
    assert.deepEqual(state, pending)
    assert.equal(lost, false)
    assert.deepEqual(position(state, server), {x: 150, y: 220})
  })

  test(`a ${how} after the earlier move failed goes back with the notice`, () => {
    const pending = pendingMove()
    const press = pressPending(pending)
    const answered = settle(press, pending.token, "failed")
    assert.equal(answered.lost, false)
    assert.deepEqual(position(answered.state, server), {x: 150, y: 220})
    const {state, lost} = end(answered.state)
    assert.equal(lost, true)
    assert.deepEqual(position(state, server), server)
  })

  test(`a ${how} after the earlier move saved ends quietly`, () => {
    const pending = pendingMove()
    const {state} = settle(pressPending(pending), pending.token, "ok")
    const ended = end(state)
    assert.equal(ended.state, null)
    assert.equal(ended.lost, false)
  })
}

test("the kept move still settles, by its own token", () => {
  const pending = pendingMove()
  const {state} = release(pressPending(pending), true)
  assert.deepEqual(settle(state, pending.token, "ok"), {state: null, lost: false})
  assert.deepEqual(settle(cancel(pressPending(pending)).state, pending.token, "conflict"), {state: null, lost: true})
})

test("a real drag from a pending card replaces it, and the earlier answer leaves it alone", () => {
  const pending = pendingMove()
  const {state, command, lost} = release(move(pressPending(pending), {x: 30, y: 0}), true)
  assert.deepEqual(command, {x: 180, y: 220})
  assert.equal(lost, false)
  assert.equal(state.token, 2)
  for (const status of ["ok", "conflict"]) assert.deepEqual(settle(state, pending.token, status), {state, lost: false})
  assert.deepEqual(settle(state, 2, "ok"), {state: null, lost: false})
})

test("a real drag isn't told about the earlier move's failure unless it is abandoned", () => {
  const pending = pendingMove()
  const moved = move(pressPending(pending), {x: 30, y: 0})
  const {state, lost} = settle(moved, pending.token, "failed")
  assert.equal(lost, false)
  assert.deepEqual(position(state, server), {x: 180, y: 220})
  assert.equal(release(state, true).lost, false)
  assert.equal(cancel(state).lost, true)
})

test("a disconnect reaches a move kept under a press", () => {
  const pending = pendingMove()
  const press = pressPending(pending)
  assert.equal(awaited(pending), pending.token)
  assert.equal(awaited(press), pending.token)
  assert.equal(awaited(dragged()), undefined)
  assert.equal(awaited(undefined), undefined)
  const {state} = settle(press, awaited(press), "disconnected")
  assert.equal(release(state, true).lost, true)
})

test("a settle with no awaited token changes nothing", () => {
  const state = dragged()
  assert.deepEqual(settle(state, awaited(state), "disconnected"), {state, lost: false})
})

test("a card gone mid-gesture cancels it: no state, no command, no notice", () => {
  assert.equal(move(undefined, {x: 1, y: 1}), undefined)
  assert.deepEqual(release(undefined, true), {state: null, command: null, lost: false})
  assert.deepEqual(cancel(undefined), {state: null, lost: false})
})

test("a move with the primary button up means the release was lost", () => {
  assert.equal(buttonUp({buttons: 0}), true)
  assert.equal(buttonUp({buttons: 2}), true)
  assert.equal(buttonUp({buttons: 1}), false)
  assert.equal(buttonUp({buttons: 3}), false)
})

test("after a reconnect the server position shows", () => {
  assert.deepEqual(position(null, {x: 7, y: 8}), {x: 7, y: 8})
})

test("the click threshold is a distance, in any direction", () => {
  assert.equal(pastThreshold({x: 0, y: 0}, {x: 3, y: 0}), false)
  assert.equal(pastThreshold({x: 0, y: 0}, {x: 3, y: 3}), true)
})
