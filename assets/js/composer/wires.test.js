import assert from "node:assert/strict"
import {test} from "node:test"
import {cubicPath} from "./geometry.js"
import {wirePaths} from "./wires.js"

const points = {"out:a": {x: 0, y: 0}, "in:b.f": {x: 100, y: 50}, "after-out:a": {x: 0, y: 9}, "after-in:b": {x: 90, y: 9}}

test("each edge becomes one path, keeping its kind", () => {
  const edges = [
    {from: "out:a", to: "in:b.f", kind: "value", problem: false},
    {from: "after-out:a", to: "after-in:b", kind: "after", problem: true},
  ]

  assert.deepEqual(wirePaths(edges, points), [
    {key: "out:a>in:b.f", d: cubicPath(points["out:a"], points["in:b.f"]), kind: "value", problem: false},
    {key: "after-out:a>after-in:b", d: cubicPath(points["after-out:a"], points["after-in:b"]), kind: "after", problem: true},
  ])
})

test("an edge with a socket off screen draws nothing", () => {
  assert.deepEqual(wirePaths([{from: "out:gone", to: "in:b.f", kind: "value"}], points), [])
  assert.deepEqual(wirePaths([{from: "out:a", to: "in:hidden.f", kind: "value"}], points), [])
})

test("hyphenated names keep separate keys", () => {
  const hyphens = {"after-out:a": {x: 0, y: 0}, "after-in:b-c": {x: 1, y: 1}, "after-out:a-b": {x: 2, y: 2}, "after-in:c": {x: 3, y: 3}}
  const edges = [
    {from: "after-out:a", to: "after-in:b-c", kind: "after"},
    {from: "after-out:a-b", to: "after-in:c", kind: "after"},
  ]
  const keys = wirePaths(edges, hyphens).map(path => path.key)
  assert.equal(new Set(keys).size, 2)
})

const lowestPoint = d => Math.max(...[...d.matchAll(/(-?[\d.]+) (-?[\d.]+)/g)].map(match => Number(match[2])))

test("a wire to a card further left loops under the cards it would run behind", () => {
  const points = {out: {x: 700, y: 100}, in: {x: 100, y: 90}}
  const cards = [
    {left: 100, right: 380, bottom: 200},
    {left: 420, right: 700, bottom: 260},
    {left: 900, right: 1200, bottom: 999},
  ]
  const [{d}] = wirePaths([{from: "out", to: "in", kind: "rerun"}], points, cards)

  assert.match(d, /^M 700 100 /)
  assert.match(d, / 100 90$/)
  assert.ok(lowestPoint(d) > 260, d)
  assert.ok(lowestPoint(d) < 999, d)
})

test("a wire to a card further right stays a plain curve between them", () => {
  const points = {out: {x: 100, y: 100}, in: {x: 700, y: 100}}
  const cards = [{left: -180, right: 100, bottom: 300}, {left: 700, right: 980, bottom: 300}]
  const [{d}] = wirePaths([{from: "out", to: "in", kind: "next"}], points, cards)

  assert.ok(lowestPoint(d) <= 100, d)
})
