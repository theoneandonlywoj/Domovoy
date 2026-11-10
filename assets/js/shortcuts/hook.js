// Page shortcuts on the dashboard shell: a prefix key (`g`) then a second key clicks the
// `[data-shortcut]` element bound to that pair, so its `<.link navigate>` runs as on a mouse
// click. `?` toggles hint badges on <html>, Escape hides them. Keys come from priv/keymap.json.
import {PREFIX_TIMEOUT_MS, decide, modalOpen, typing} from "./keys.js"

export default {
  mounted() {
    this.prefixes = (this.el.dataset.prefixes || "").split(" ").filter(Boolean)
    this.hintsKey = this.el.dataset.hintsKey
    this.pending = null
    this.timer = null
    this.onKey = e => this.keyDown(e)
    // Capture: runs before the dev live-reloader's bubble keydown records the key (app.js),
    // which would otherwise swallow the click on `g d`.
    window.addEventListener("keydown", this.onKey, {capture: true})
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey, {capture: true})
    this.clear() // keeps html[data-hints] so hints survive the navigation the shortcut causes
  },
  clear() {
    clearTimeout(this.timer)
    this.timer = null
    this.pending = null
    delete document.documentElement.dataset.hintsPrefix
  },
  keyDown(e) {
    const root = document.documentElement
    const action = decide({
      key: e.key, altKey: e.altKey, metaKey: e.metaKey, ctrlKey: e.ctrlKey,
      repeat: e.repeat, isComposing: e.isComposing,
      typing: typing(e.target), modal: modalOpen(document),
      pending: this.pending, prefixes: this.prefixes, hintsKey: this.hintsKey,
    })
    switch (action.type) {
      case "arm":
        this.clear()
        this.pending = action.prefix
        root.dataset.hintsPrefix = action.prefix
        this.timer = setTimeout(() => this.clear(), PREFIX_TIMEOUT_MS)
        e.preventDefault()
        break
      case "go": {
        this.clear()
        const target = [...document.querySelectorAll("[data-shortcut]")].find(el => el.dataset.shortcut === action.combo)
        if (!target) break
        e.preventDefault()
        // Going to the page you are on does nothing (keeps e.g. ?q= filters). Compare paths, not
        // aria-current: on /dashboard/workflows/:id the Workflows link is current but `g w` must still go.
        if (target.href && new URL(target.href).pathname === location.pathname) break
        // .click() copies the current modifier state; Cmd/Ctrl/Alt are rejected above, and a future
        // Shift binding would make LiveView treat it as "open in new tab".
        target.click()
        break
      }
      case "hints":
        if (root.dataset.hints === "on") delete root.dataset.hints
        else root.dataset.hints = "on"
        e.preventDefault()
        break
      case "hide":
        this.clear()
        delete root.dataset.hints // no preventDefault: the composer and dialogs still see Escape
        break
      case "clear":
        this.clear()
        break
    }
  },
}
