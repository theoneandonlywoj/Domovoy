// Page shortcuts on the dashboard shell: a prefix key (`g`, `f`) then a second key clicks the
// `[data-shortcut]` element bound to that pair, so its `<.link navigate>` or `<.link patch>` runs as
// on a mouse click. The focus key (`/`) and Cmd/Ctrl+K focus the input of the `[data-shortcut-focus]`
// element bound to `/`; Esc in it blurs and returns focus. `?` toggles hint badges on <html>, Escape
// hides them. Keys come from priv/keymap.json.
import {PREFIX_TIMEOUT_MS, decide, modalOpen, typing} from "./keys.js"

export default {
  mounted() {
    this.prefixes = (this.el.dataset.prefixes || "").split(" ").filter(Boolean)
    this.hintsKey = this.el.dataset.hintsKey
    this.focusKey = this.el.dataset.focusKey
    this.returnTo = null
    this.pending = null
    this.timer = null
    this.onKey = e => this.keyDown(e)
    // Capture: runs before the dev live-reloader's bubble keydown records the key (app.js),
    // which would otherwise swallow the click on `g d`.
    window.addEventListener("keydown", this.onKey, {capture: true})
    // Forget the Esc return target as soon as focus goes anywhere outside the search field.
    this.onFocusIn = e => { if (!e.target?.closest?.("[data-shortcut-focus]")) this.returnTo = null }
    window.addEventListener("focusin", this.onFocusIn)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey, {capture: true})
    window.removeEventListener("focusin", this.onFocusIn)
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
    if (e.key === "Escape" && !e.isComposing && e.target?.closest?.("[data-shortcut-focus]")) {
      e.preventDefault()
      this.clear()
      delete root.dataset.hints
      e.target.blur() // blur flushes a pending phx-debounce "search", so the typed query is kept
      const back = this.returnTo
      this.returnTo = null
      if (back && back.isConnected && typeof back.focus === "function") back.focus()
      return
    }
    const action = decide({
      key: e.key, altKey: e.altKey, metaKey: e.metaKey, ctrlKey: e.ctrlKey,
      repeat: e.repeat, isComposing: e.isComposing,
      typing: typing(e.target), modal: modalOpen(document),
      pending: this.pending, prefixes: this.prefixes, hintsKey: this.hintsKey,
      focusKey: this.focusKey,
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
        // A target behind the open overlay drawer's scrim (a filter chip) is never clicked.
        const drawer = document.querySelector("#dashboard-drawer[aria-modal='true']")
        if (drawer && !drawer.contains(target)) break
        e.preventDefault()
        // Going to the page you are on does nothing, so `g j` keeps ?q= filters. The exception is a
        // LiveView patch link (a filter chip) whose query differs: `f 2` must still patch the status.
        // Compare paths, not aria-current: on /dashboard/workflows/:id the Workflows link is current but `g w` must still go.
        if (target.href) {
          const url = new URL(target.href, location.href)
          const samePath = url.pathname === location.pathname
          if (samePath && !(target.dataset.phxLink === "patch" && url.search !== location.search)) break
        }
        // .click() copies the current modifier state; Cmd/Ctrl/Alt are rejected above, and a future
        // Shift binding would make LiveView treat it as "open in new tab".
        target.click()
        break
      }
      case "focus": {
        this.clear()
        if (document.querySelector("#dashboard-drawer[aria-modal='true']")) break // the field is behind the scrim
        const field = [...document.querySelectorAll("[data-shortcut]")].find(el => el.dataset.shortcut === action.combo)
        if (!field || !field.hasAttribute("data-shortcut-focus")) break // never click on a modifier; keep the browser default
        e.preventDefault()
        const active = document.activeElement
        if (active && active !== document.body && !field.contains(active)) this.returnTo = active
        field.querySelector("input")?.focus()
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
