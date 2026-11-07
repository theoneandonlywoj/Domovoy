import {cubicPath, loopPath} from "./geometry.js"

const BELOW_CARDS = 32

// The lowest edge of the cards between the two ends, which a loop has to clear.
function clearance(from, to, cards) {
  const between = cards.filter(card => card.right >= to.x && card.left <= from.x)
  return Math.max(from.y, to.y, ...between.map(card => card.bottom)) + BELOW_CARDS
}

// One path per edge whose two sockets are on screen. A source visible to the stage has a
// node. One that isn't visible, or a field in a collapsed list, has no point and draws no
// wire: its row still says what it reads. `points` maps a socket to its world point, and `cards` are world boxes.
export function wirePaths(edges, points, cards = []) {
  return edges.flatMap(edge => {
    const from = points[edge.from]
    const to = points[edge.to]
    if (!from || !to) return []
    const d = to.x < from.x ? loopPath(from, to, clearance(from, to, cards)) : cubicPath(from, to)
    const path = {key: `${edge.from}>${edge.to}`, d, kind: edge.kind, problem: edge.problem}
    // A run's status, only on a wire the run has travelled.
    return [edge.run ? {...path, run: edge.run} : path]
  })
}
