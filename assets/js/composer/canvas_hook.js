// The canvas's pointer layer. It owns the wire SVG and the viewport; cards stay
// server-rendered. Writing a card's `style` is attribute control, not DOM ownership: a
// patch resets it, the observer below puts it back before paint, and every write is
// skipped when the value is already right, so that observer can't loop.
//
// The hook sits on the ignored wire layer because `pushEvent` locks its element, and
// that lock must not cover the cards.
import * as Drag from "./drag.js"
import {cubicPath, sliderMax, socketPoint, worldBox, zoomAt} from "./geometry.js"
import {escapeAction, isEditable, isUndo} from "./keys.js"
import {PIN_DEFAULT, canPin, clampWidth} from "./panels.js"
import {actualSize, fitSelection, fitView, initial, panBy, reveal, transform, wheel} from "./viewport.js"
import {wirePaths} from "./wires.js"

const SVG_NS = "http://www.w3.org/2000/svg"
const NOT_SAVED = "That move wasn't saved, so the card went back."
const NOT_CONNECTED = "Not connected, so nothing changed."
const PIN_REFUSED = "Not enough room to pin: the canvas needs at least 600 px."
// Only the dock preference is kept: no ids, names or values.
const PIN_KEY = "composer:pin"
const PIN_STEP = 16
// The controls a press on a card leaves alone. Its name button drags too, because it
// fills the header; a press with no movement still clicks it.
const CARD_CONTROLS = "a, button:not([data-card-grip]), input, select, textarea, summary, label, [data-socket]"
const CANVAS_CONTROLS = "a, button, input, select, textarea, summary, label, [contenteditable], [data-socket], [data-canvas-control]"
const ESCAPE_BUTTONS = {
  picker: ["connect-close", "close-picker"],
  tools: ["close-tools"],
  outline: ["close-outline-panel"],
  selection: ["deselect-node"],
  canvasOnly: ["exit-canvas-only"],
}

const setAttr = (el, name, value) => {
  if (value === null) {
    if (el.hasAttribute(name)) el.removeAttribute(name)
  } else if (el.getAttribute(name) !== value) {
    el.setAttribute(name, value)
  }
}

export default {
  mounted() {
    this.composer = this.el.closest("#composer")
    this.canvas = this.el.closest("#stage-canvas")
    this.world = this.el.closest("#stage-world")
    this.workspace = this.el.closest("#workspace")
    this.notice = this.canvas.querySelector("#canvas-notice")
    this.say("")
    this.level = this.world.dataset.level
    this.view = initial()
    this.pin = this.loadPin()
    this.moves = new Map()
    this.gesture = null
    this.token = 0
    this.frame = null
    this.svg = document.createElementNS(SVG_NS, "svg")
    this.svg.setAttribute("aria-hidden", "true")
    this.el.appendChild(this.svg)

    this.listeners = [
      [this.composer, "pointerdown", e => this.pointerDown(e)],
      [this.composer, "pointermove", e => this.pointerMove(e)],
      [this.composer, "pointerup", e => this.pointerUp(e)],
      [this.composer, "pointercancel", () => this.cancelGesture()],
      [this.composer, "lostpointercapture", e => this.captureLost(e)],
      [this.composer, "contextmenu", () => this.cancelGesture()],
      [this.composer, "click", e => this.swallowClick(e), {capture: true}],
      [this.composer, "scroll", () => this.scheduleDraw(), {capture: true, passive: true}],
      [this.composer, "click", e => this.togglePin(e)],
      [this.canvas, "click", e => this.zoomCommand(e)],
      [this.canvas, "input", e => this.zoomSlider(e)],
      [this.canvas, "wheel", e => this.onWheel(e), {passive: false}],
      [this.canvas, "dblclick", e => this.openCard(e)],
      [window, "keydown", e => this.keyDown(e)],
    ]
    for (const [target, name, fn, options] of this.listeners) target.addEventListener(name, fn, options)

    this.mutations = new MutationObserver(() => {
      this.sync()
      this.scheduleDraw()
    })
    this.mutations.observe(this.composer, {attributes: true, childList: true, characterData: true, subtree: true})
    // A narrower workspace may undock the inspector, so a resize syncs as well as draws.
    this.resizes = new ResizeObserver(() => {
      this.sync()
      this.scheduleDraw()
    })
    this.resizes.observe(this.canvas)
    this.resizes.observe(this.workspace)

    this.handleEvent("composer:focus", ({id}) => {
      this.pendingFocus = id
      this.syncFocus()
    })
    // A remembered dock is applied first, so the first fit measures the canvas beside it.
    this.syncDock()
    this.refit()
    this.sync()
    this.draw()
  },

  destroyed() {
    for (const [target, name, fn, options] of this.listeners) target.removeEventListener(name, fn, options)
    this.mutations.disconnect()
    this.resizes.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
  },

  // A push in flight when the socket drops could stay pending for 30 seconds.
  disconnected() {
    for (const [node, move] of this.moves) this.settle(node, Drag.awaited(move), "disconnected")
  },

  // The server may have saved before its answer got lost, so its position wins, and a
  // notice from before can't be trusted.
  reconnected() {
    this.say("")
    this.sync()
    this.scheduleDraw()
  },

  // Keeping the DOM right

  cards() {
    return this.world.querySelectorAll("article[data-node]")
  },

  serverPosition(card) {
    return {x: Number(card.dataset.x), y: Number(card.dataset.y)}
  },

  // A card's world box, through `data-x/y` and offset sizes, which a world transform
  // doesn't change.
  cardBox(card) {
    const {x, y} = Drag.position(this.moves.get(card.dataset.node), this.serverPosition(card))
    return {left: x, top: y, right: x + card.offsetWidth, bottom: y + card.offsetHeight}
  },

  selectedCard() {
    const selected = this.canvas.dataset.selected
    return selected === undefined ? null : [...this.cards()].find(card => card.dataset.node === selected)
  },

  // `view.zoom` stays the true scale; `fit` is the scale shown as 100%, and only this and a
  // level change measure it.
  refit() {
    this.view = fitView([...this.cards()].map(card => this.cardBox(card)), this.canvas.getBoundingClientRect())
    this.fit = this.view.zoom
  },

  // Puts back what a patch reset. Runs before paint, from the observer.
  sync() {
    // The workflow and each stage are separate worlds, sharing this layer across a patch.
    if (this.world.dataset.level !== this.level) {
      this.level = this.world.dataset.level
      this.moves.clear()
      this.refit()
      const gesture = this.gesture
      this.gesture = null
      if (gesture) this.endWire(gesture)
    }
    this.syncDock()
    setAttr(this.world, "style", `transform: ${transform(this.view)};`)
    setAttr(this.canvas, "data-gesture", this.gesture ? "true" : null)

    const seen = new Set()
    for (const card of this.cards()) {
      const node = card.dataset.node
      seen.add(node)
      const {x, y} = Drag.position(this.moves.get(node), this.serverPosition(card))
      if (card.style.left !== `${x}px`) card.style.left = `${x}px`
      if (card.style.top !== `${y}px`) card.style.top = `${y}px`
    }
    for (const node of this.moves.keys()) if (!seen.has(node)) this.moves.delete(node)

    this.syncZoom()
    this.syncWiring()
    this.syncFocus()
  },

  syncZoom() {
    const percent = this.canvas.querySelector("#canvas-zoom-percent")
    const fit = this.fit ?? 1
    const value = String(Math.round((this.view.zoom / fit) * 100))
    const label = `Fit · ${value}%`
    if (percent && percent.textContent !== label) percent.textContent = label
    const slider = this.canvas.querySelector("#canvas-zoom-slider")
    if (slider) {
      // Before the value, because a browser clamps a value to the current max.
      setAttr(slider, "max", String(sliderMax(fit)))
      if (slider.value !== value) slider.value = value
      setAttr(slider, "aria-valuetext", label)
    }
  },

  // The inspector docks while it is shown, pinned and leaves the canvas room; otherwise it
  // floats and the preference waits. Showing it, or changing the dock, pans only to reveal
  // the selected card from under it.
  syncDock() {
    const inspector = this.workspace.querySelector("#inspector-panel")
    const docked = Boolean(inspector) && this.pin.pinned && !this.composer.hasAttribute("data-canvas-only") &&
      canPin(this.workspace.clientWidth, this.pin.width)
    setAttr(this.workspace, "data-pinned", docked ? "true" : null)
    setAttr(this.workspace, "style", docked ? `--pin-width: ${this.pin.width}px;` : null)
    const pin = this.workspace.querySelector("#pin-inspector")
    if (pin) setAttr(pin, "aria-pressed", String(docked))
    const handle = this.workspace.querySelector("#inspector-resize")
    if (handle) setAttr(handle, "aria-valuenow", String(this.pin.width))

    // Nothing to reveal before the first fit, nor during a gesture other than resizing.
    if (this.fit === undefined || (this.gesture && this.gesture.kind !== "resize")) return
    const shown = inspector ? `${this.canvas.dataset.selected}:${docked && this.pin.width}` : null
    if (shown === this.inspectorShown) return
    this.inspectorShown = shown
    if (inspector) this.revealSelected(inspector)
  },

  revealSelected(inspector) {
    const card = this.selectedCard()
    if (!card) return
    const canvas = this.canvas.getBoundingClientRect()
    const panel = inspector.getBoundingClientRect()
    const box = this.cardBox(card)
    // The panel's rect in canvas coordinates; a hidden one has no size.
    const left = panel.left - canvas.left, top = panel.top - canvas.top
    const screen = {
      left: box.left * this.view.zoom + this.view.x,
      right: box.right * this.view.zoom + this.view.x,
      top: box.top * this.view.zoom + this.view.y,
      bottom: box.bottom * this.view.zoom + this.view.y,
    }
    const covered = panel.width > 0 && screen.right > left && screen.left < left + panel.width &&
      screen.bottom > top && screen.top < top + panel.height
    if (!covered || left <= 0) return
    this.view = reveal(this.view, box, {left: 0, top: 0, right: Math.min(canvas.width, left), bottom: canvas.height})
  },

  loadPin() {
    try {
      const saved = JSON.parse(localStorage.getItem(PIN_KEY))
      return {pinned: saved?.pinned === true, width: clampWidth(Number(saved?.width) || PIN_DEFAULT)}
    } catch {
      return {pinned: false, width: PIN_DEFAULT}
    }
  },

  savePin() {
    try {
      localStorage.setItem(PIN_KEY, JSON.stringify({pinned: this.pin.pinned, width: this.pin.width}))
    } catch {
      // Storage may be off; the dock still works for this page.
    }
  },

  // The pin button sits outside the canvas, so this listens on the composer. It acts on
  // the dock it reports: a stored pin that can't dock now is refused, not dropped.
  togglePin(event) {
    if (!event.target.closest("#pin-inspector")) return
    if (this.workspace.hasAttribute("data-pinned")) this.pin = {...this.pin, pinned: false}
    else if (canPin(this.workspace.clientWidth, this.pin.width)) this.pin = {...this.pin, pinned: true}
    else return this.say(PIN_REFUSED)
    this.savePin()
    this.sync()
    this.scheduleDraw()
  },

  // A width that would leave the canvas too little room is skipped.
  resizeDock(width) {
    const next = clampWidth(width)
    if (next === this.pin.width || !canPin(this.workspace.clientWidth, next)) return
    this.pin = {...this.pin, width: next}
    this.sync()
    this.scheduleDraw()
  },

  // A server-selected issue target may arrive after the event, in the next patch.
  syncFocus() {
    if (typeof document === "undefined") return
    const tools = document.getElementById("composer-tools")
    const inspector = document.getElementById("inspector-panel")
    const confirmation = document.getElementById("confirm-replace-literal")
    const clear = document.getElementById("clear-preview")
    const activeId = document.activeElement?.id
    if (tools && !this.toolsMounted) {
      this.toolsReturnFocus = activeId
      if (!this.pendingFocus && !confirmation) document.getElementById("close-tools")?.focus()
    }
    if (clear && !this.clearMounted) {
      this.clearReturnFocus = activeId
      document.getElementById("cancel-clear-input")?.focus()
    }
    if (this.clearMounted && !clear && document.activeElement === document.body) {
      const target = document.getElementById(this.clearReturnFocus) || document.getElementById("open-tools")
      target?.focus()
    }
    if ((this.toolsMounted && !tools) || (this.inspectorMounted && !inspector) || (this.confirmationMounted && !confirmation)) {
      if (!document.activeElement || document.activeElement === document.body) {
        const target = document.getElementById(this.toolsReturnFocus)
        ;(target || document.getElementById("open-tools"))?.focus()
      }
    }
    const exit = document.getElementById("exit-canvas-only")
    if (this.canvasOnlyMounted && !exit && (!document.activeElement || document.activeElement === document.body)) {
      document.getElementById("canvas-only")?.focus()
    }
    this.canvasOnlyMounted = Boolean(exit)
    this.toolsMounted = Boolean(tools)
    this.inspectorMounted = Boolean(inspector)
    this.confirmationMounted = Boolean(confirmation)
    this.clearMounted = Boolean(clear)
    if (this.pendingFocus) {
      const target = document.getElementById(this.pendingFocus)
      if (target) {
        target.focus()
        this.pendingFocus = null
      }
    }
  },

  syncWiring() {
    const wire = this.gesture?.kind === "wire" && this.gesture.moved ? this.gesture : null
    setAttr(this.composer, "data-wiring", wire ? "true" : null)

    for (const socket of this.canvas.querySelectorAll("[data-socket]")) {
      const target = wire?.targets?.get(socket.dataset.socket)
      const fits = Boolean(target) && target.fit !== "incompatible"
      setAttr(socket, "data-compat", fits ? "true" : null)
      const list = fits ? socket.closest("details") : null
      if (list && !list.open) {
        list.open = true
        wire.opened.add(list)
      }
    }
  },

  scheduleDraw() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.draw()
    })
  },

  draw() {
    const origin = this.world.getBoundingClientRect()
    const points = {}
    for (const socket of this.composer.querySelectorAll("[data-socket]")) {
      const rect = socket.getBoundingClientRect()
      if (rect.width > 0) points[socket.dataset.socket] = socketPoint(rect, origin, this.view.zoom)
    }

    const cards = [...this.cards()].map(card => worldBox(card.getBoundingClientRect(), origin, this.view.zoom))
    const paths = wirePaths(JSON.parse(this.el.dataset.edges || "[]"), points, cards)
    const wire = this.gesture?.kind === "wire" && this.gesture.moved ? this.gesture : null
    if (wire && points[wire.socket]) {
      const end = wire.over ? points[wire.over.socket] : null
      paths.push({
        key: "preview",
        d: cubicPath(points[wire.socket], end ?? socketPoint({left: wire.pointer.x, top: wire.pointer.y, width: 0, height: 0}, origin, this.view.zoom)),
        kind: wire.over && !wire.over.fits ? "preview-refused" : "preview",
      })
    }
    this.drawPaths(paths)
  },

  // Keyed, and writing only what differs, so a redraw changes nothing when nothing moved.
  drawPaths(paths) {
    const existing = new Map([...this.svg.children].map(path => [path.dataset.key, path]))
    for (const {key, d, kind, problem, run} of paths) {
      let path = existing.get(key)
      existing.delete(key)
      if (!path) {
        path = document.createElementNS(SVG_NS, "path")
        path.dataset.key = key
        this.svg.appendChild(path)
      }
      setAttr(path, "d", d)
      setAttr(path, "class", `wire wire-${kind}${problem ? " wire-problem" : ""}${run ? ` wire-run-${run}` : ""}`)
    }
    for (const path of existing.values()) path.remove()
  },

  say(text) {
    this.notice.textContent = text
  },

  // Pointer

  pointerDown(event) {
    this.clickSwallowed = false
    // A new press from the same pointer means the last one's release never came.
    if (this.gesture?.pointerId === event.pointerId) this.cancelGesture()
    if (event.button !== 0 || this.gesture) return
    const pointer = {x: event.clientX, y: event.clientY}
    const socket = event.target.closest("[data-source], [data-after-source]")

    if (event.target.closest("#inspector-resize")) {
      event.preventDefault()
      this.gesture = {kind: "resize", pointer, start: pointer, width: this.pin.width, pointerId: event.pointerId, moved: false}
      return
    }
    if (event.target.closest("[data-canvas-control]")) return
    // A run is read-only: its sockets and cards start nothing, and the canvas still pans.
    if (this.readOnly() && (socket || event.target.closest("article[data-node]"))) return
    if (socket) {
      event.preventDefault()
      this.beginWire(socket, pointer, event.pointerId)
    } else if (this.canvas.contains(event.target)) {
      const card = event.target.closest("article[data-node]")
      if (card) this.beginCard(card, event.target, pointer, event.pointerId)
      else if (!event.target.closest(CANVAS_CONTROLS)) this.gesture = {kind: "pan", pointer, start: pointer, pointerId: event.pointerId, moved: false}
    }
  },

  readOnly() {
    return this.canvas.dataset.readOnly !== undefined
  },

  beginCard(card, target, pointer, pointerId) {
    if (target.closest(CARD_CONTROLS)) return
    const node = card.dataset.node
    // A card still awaiting an answer drags from where it shows.
    const prior = this.moves.get(node)
    const from = Drag.position(prior, this.serverPosition(card))
    this.moves.set(node, Drag.start({from, pointer, zoom: this.view.zoom, token: ++this.token, prior}))
    this.gesture = {kind: "card", node, pointerId, moved: false}
  },

  beginWire(socket, pointer, pointerId) {
    const after = socket.dataset.afterSource !== undefined
    const source = after ? socket.dataset.afterSource : socket.dataset.source
    const gesture = {
      kind: "wire",
      after,
      source,
      socket: socket.dataset.socket,
      pointerId,
      pointer,
      start: pointer,
      moved: false,
      targets: null,
      over: null,
      opened: new Set(),
    }
    this.gesture = gesture

    if (!this.liveSocket.isConnected()) return
    this.pushEvent("connect_preview", {source, kind: after ? "after" : "value"})
      .then(reply => {
        gesture.targets = new Map((reply?.targets ?? []).map(target => [target.socket, target]))
        if (this.gesture === gesture) {
          this.syncWiring()
          this.updateOver(gesture)
          this.scheduleDraw()
        }
      })
      .catch(() => {})
  },

  pointerMove(event) {
    const gesture = this.gesture
    if (!gesture || event.pointerId !== gesture.pointerId) return
    if (Drag.buttonUp(event)) return this.cancelGesture()
    const pointer = {x: event.clientX, y: event.clientY}

    if (gesture.kind === "card") {
      const move = Drag.move(this.moves.get(gesture.node), pointer)
      if (!move) return this.cancelGesture()
      this.moves.set(gesture.node, move)
      if (move.moved) this.beginMoving(gesture)
    } else {
      if (!gesture.moved && !Drag.pastThreshold(gesture.start, pointer)) return
      this.beginMoving(gesture)
      if (gesture.kind === "pan") this.view = panBy(this.view, pointer.x - gesture.pointer.x, pointer.y - gesture.pointer.y)
      // The handle is on the dock's left edge, so dragging left widens it.
      if (gesture.kind === "resize") this.resizeDock(gesture.width + gesture.start.x - pointer.x)
      gesture.pointer = pointer
      if (gesture.kind === "wire") this.updateOver(gesture)
    }
    this.sync()
    this.scheduleDraw()
  },

  // Capture only once it is a drag, because a captured press no longer clicks its target.
  beginMoving(gesture) {
    if (gesture.moved) return
    gesture.moved = true
    this.say("")
    this.composer.setPointerCapture(gesture.pointerId)
  },

  pointerUp(event) {
    const gesture = this.gesture
    if (!gesture || event.pointerId !== gesture.pointerId) return
    this.gesture = null
    this.clickSwallowed = gesture.moved

    if (gesture.kind === "card") this.releaseCard(gesture)
    else if (gesture.kind === "wire") this.dropWire(gesture, event)
    else if (gesture.kind === "resize") this.savePin()
    else if (!gesture.moved && !Drag.pastThreshold(gesture.start, {x: event.clientX, y: event.clientY}) &&
      this.canvas.contains(event.target) && !event.target.closest(`article[data-node], ${CANVAS_CONTROLS}`)) {
      this.push("deselect_node", {})
    }
    this.endWire(gesture)
    this.sync()
    this.scheduleDraw()
  },

  cancelGesture() {
    const gesture = this.gesture
    if (!gesture) return
    this.gesture = null
    this.endWire(gesture)
    this.say("")
    if (gesture.kind === "card") this.record(gesture.node, Drag.cancel(this.moves.get(gesture.node)))
    if (gesture.kind === "resize") this.pin = {...this.pin, width: gesture.width}
    this.sync()
    this.scheduleDraw()
  },

  captureLost(event) {
    if (event.pointerId === this.gesture?.pointerId) this.cancelGesture()
  },

  endWire(gesture) {
    if (gesture.kind !== "wire") return
    this.clearHover(gesture)
    for (const list of gesture.opened) list.open = false
  },

  // A press that became a drag must not also click what it started on. Some browsers
  // send that click to the capturing element, and some don't send one, so
  // `pointerDown` clears this.
  swallowClick(event) {
    if (!this.clickSwallowed) return
    this.clickSwallowed = false
    event.stopPropagation()
    event.preventDefault()
  },

  // Fit re-measures the canvas as it is now; Fit selection and Actual size move the view
  // only, so the percentage keeps meaning the last fit.
  zoomCommand(event) {
    const button = event.target.closest("#canvas-fit, #canvas-fit-selection, #canvas-actual-size")
    if (!button) return
    event.preventDefault()
    if (this.gesture) return
    const rect = this.canvas.getBoundingClientRect()
    if (button.id === "canvas-fit") {
      this.refit()
    } else if (button.id === "canvas-actual-size") {
      this.view = actualSize(this.view, {x: rect.width / 2, y: rect.height / 2}, this.fit ?? 1)
    } else {
      const card = this.selectedCard()
      if (card) this.view = fitSelection(this.cardBox(card), rect)
    }
    this.sync()
    this.scheduleDraw()
  },

  // Zooms at the canvas's centre. During a gesture, `sync` puts the slider back.
  zoomSlider({target}) {
    if (target.id !== "canvas-zoom-slider") return
    if (!this.gesture) {
      const rect = this.canvas.getBoundingClientRect()
      const fit = this.fit ?? 1
      this.view = zoomAt(this.view, {x: rect.width / 2, y: rect.height / 2}, fit * Number(target.value) / 100, fit)
    }
    this.sync()
    this.scheduleDraw()
  },

  onWheel(event) {
    event.preventDefault()
    if (this.gesture) return
    const rect = this.canvas.getBoundingClientRect()
    this.view = wheel(this.view, event, {x: event.clientX - rect.left, y: event.clientY - rect.top}, this.fit ?? 1)
    this.sync()
    this.scheduleDraw()
  },

  // A Stage card holds the link that opens it, so this is that link's own navigation.
  openCard(event) {
    if (event.target.closest("[data-socket]")) return
    event.target.closest("article[data-node]")?.querySelector("[data-card-open]")?.click()
  },

  // Moving a card

  releaseCard({node}) {
    const released = Drag.release(this.moves.get(node), this.liveSocket.isConnected())
    this.record(node, released)
    const {command, state} = released
    if (!command) return

    const {token} = state
    this.pushEvent("node_moved", {node, x: command.x, y: command.y, level: this.level})
      .then(reply => this.settle(node, token, reply?.status))
      .catch(() => this.settle(node, token, "failed"))
  },

  settle(node, token, status) {
    this.record(node, Drag.settle(this.moves.get(node), token, status))
    this.sync()
    this.scheduleDraw()
  },

  record(node, {state, lost}) {
    if (state) this.moves.set(node, state)
    else this.moves.delete(node)
    if (lost) this.say(NOT_SAVED)
  },

  // Connecting

  // What the pointer is over, from the browser's own hit test.
  hit(pointer) {
    return document.elementFromPoint(pointer.x, pointer.y)
  },

  // A value connection lands on a field row, and an After connection on a whole card.
  dropTarget(gesture) {
    const el = this.hit(gesture.pointer)
    if (!el || !this.canvas.contains(el)) return null
    if (gesture.after) {
      const card = el.closest("article[data-node]")
      if (!card || card.dataset.node === gesture.source || card.dataset.sourceNode !== undefined) return null
      return {el: card, socket: card.querySelector(`header > [data-socket^="after-in:"]`).dataset.socket}
    }
    const row = el.closest("li[data-field]")
    if (!row) return null
    return {el: row, socket: row.querySelector(":scope > [data-socket]").dataset.socket}
  },

  updateOver(gesture) {
    if (gesture.moved && !gesture.after) this.openListUnderPointer(gesture)
    const found = gesture.moved ? this.dropTarget(gesture) : null
    const target = found && gesture.targets?.get(found.socket)
    const fits = target ? target.fit !== "incompatible" : !gesture.targets

    this.clearHover(gesture)
    gesture.over = found ? {...found, fits} : null
    if (found) {
      setAttr(found.el, "data-drop-hover", fits ? "fits" : "refused")
      if (target) this.say(fits ? target.label : `${target.label}: this won't fit. Drop to see why.`)
      else this.say("")
    } else {
      this.say("")
    }
  },

  // A field that doesn't fit can still be dropped on, for its explanation and adapters,
  // so the card under the pointer shows all its fields.
  openListUnderPointer(gesture) {
    const list = this.hit(gesture.pointer)?.closest("article[data-node]")?.querySelector("details")
    if (list && !list.open) {
      list.open = true
      gesture.opened.add(list)
    }
  },

  clearHover(gesture) {
    if (gesture.over) setAttr(gesture.over.el, "data-drop-hover", null)
  },

  dropWire(gesture, event) {
    if (!gesture.moved) return
    gesture.pointer = {x: event.clientX, y: event.clientY}
    const found = this.dropTarget(gesture)
    this.say("")

    if (gesture.after) {
      if (found) this.push("add_after", {after: {node: found.el.dataset.node, source: gesture.source}})
    } else if (found) {
      const {node, field} = found.el.dataset
      this.push("connect", {source: gesture.source, node, field})
    } else if (this.overEmptyCanvas(gesture.pointer)) {
      this.push("open_picker", {source: gesture.source})?.then(() =>
        document.getElementById("catalog_text")?.focus(),
      )
    }
  },

  overEmptyCanvas(pointer) {
    const el = this.hit(pointer)
    return Boolean(el) && this.canvas.contains(el) && !el.closest("article")
  },

  push(event, payload) {
    if (!this.liveSocket.isConnected()) {
      this.say(NOT_CONNECTED)
      return null
    }
    return this.pushEvent(event, payload).catch(() => this.say(NOT_CONNECTED))
  },

  // Keys

  keyDown(event) {
    if (isUndo(event)) {
      if (!this.readOnly() && !isEditable(event.target) && !document.getElementById("confirm-replace-literal")) {
        event.preventDefault()
        this.push("undo", {})
      }
    } else if (event.key === "Escape") {
      this.escape(event)
    } else if (event.target?.id === "inspector-resize" && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault()
      this.resizeDock(this.pin.width + (event.key === "ArrowLeft" ? PIN_STEP : -PIN_STEP))
      this.savePin()
    }
  },

  // A modal dialog handles its own Escape, with `phx-window-keydown`.
  escape(event) {
    const confirmation = Boolean(document.querySelector("[aria-modal='true']"))
    // Both pickers are covered by the confirmation. Its separate window listener
    // must be the only one to act on this key, preserving their pending state.
    const picker = !confirmation && ESCAPE_BUTTONS.picker
      .map(id => document.getElementById(id)).find(Boolean)
    const action = escapeAction({
      picker: Boolean(picker),
      confirmation,
      gesture: Boolean(this.gesture),
      tools: Boolean(document.getElementById("composer-tools")),
      outline: document.getElementById("outline-panel")?.hidden === false,
      selection: Boolean(document.getElementById("deselect-node")),
      canvasOnly: Boolean(document.getElementById("exit-canvas-only")),
      editable: isEditable(event.target),
    })

    if (action === "gesture") this.cancelGesture()
    else if (action === "picker") picker.click()
    else if (action === "tools" || action === "outline" || action === "selection" || action === "canvasOnly") {
      ESCAPE_BUTTONS[action].map(id => document.getElementById(id)).find(Boolean)?.click()
    }
  },
}
