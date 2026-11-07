// One card's move, as plain data: `dragging`, then `pending` until the server answers,
// then gone. No state means the card shows its server position. A pending move's token
// tells its answer from a later drag's, so a late answer does nothing.
//
// A press on a pending card keeps that move as `prior`, so a press that comes to nothing
// leaves it as it was. Only a new command replaces it.

const THRESHOLD = 4

// Below this a press is still a click, for every pointer gesture.
export const pastThreshold = (from, to) => Math.hypot(to.x - from.x, to.y - from.y) >= THRESHOLD

// The primary button, the only one that starts a gesture. A move without it means the
// release went somewhere the page couldn't see.
export const buttonUp = event => (event.buttons & 1) === 0

export const start = ({from, pointer, zoom, token, prior}) => ({
  phase: "dragging",
  token,
  x: from.x,
  y: from.y,
  grab: {pointer, from},
  zoom,
  moved: false,
  prior: prior ?? null,
  priorLost: false,
})

// No state means the card went away under the gesture.
export function move(state, pointer) {
  if (!state) return state
  const {grab, zoom} = state
  if (!state.moved && !pastThreshold(grab.pointer, pointer)) return state
  return {
    ...state,
    moved: true,
    x: Math.round(grab.from.x + (pointer.x - grab.pointer.x) / zoom),
    y: Math.round(grab.from.y + (pointer.y - grab.pointer.y) / zoom),
  }
}

// Gives the new state, the one command to send, and whether to tell the user the move
// was lost. A press with no movement is a click.
export function release(state, connected) {
  if (!state?.moved) return {...cancel(state), command: null}
  if (!connected) return {state: null, command: null, lost: true}
  return {state: {...state, phase: "pending", prior: null, priorLost: false}, command: {x: state.x, y: state.y}, lost: false}
}

// Ending a press without a command leaves what it found.
export const cancel = state => ({state: state?.prior ?? null, lost: Boolean(state?.priorLost)})

// The token whose answer this card is waiting for, if any.
export const awaited = state => (state?.phase === "pending" ? state.token : state?.prior?.token)

const saved = status => status === "ok" || status === "noop"

// `ok` and `noop` end the move at the server's position, like every other status, but
// only they aren't a loss. Failed pushes and dropped sockets arrive as other statuses.
export function settle(state, token, status) {
  // The press under way decides what shows, so a loss waits until it ends.
  if (state?.prior && state.prior.token === token) {
    return {state: {...state, prior: null, priorLost: !saved(status)}, lost: false}
  }
  if (!state || state.phase !== "pending" || state.token !== token) return {state, lost: false}
  return {state: null, lost: !saved(status)}
}

// While a move lives its position shows, whatever a patch says the server has. So a patch
// can't make a card jump, and a revert only has to drop the move.
export const position = (state, server) => (state ? {x: state.x, y: state.y} : server)
