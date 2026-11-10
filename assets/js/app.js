// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/domovoy"
import topbar from "../vendor/topbar"
import ComposerCanvas from "./composer/canvas_hook.js"
import Shortcuts from "./shortcuts/hook.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ComposerCanvas, Shortcuts},
})

// The bar's one toggle: collapse on desktop (remembered in a cookie), overlay on phones.
// The collapse lives on <html>, which live navigation keeps, and in a cookie the root layout reads.
window.addEventListener("domovoy:toggle", () => {
  const drawer = document.getElementById("dashboard-drawer")
  if (!drawer) return
  if (matchMedia("(width >= 48rem)").matches) {
    const root = document.documentElement
    const next = root.dataset.drawer === "collapsed" ? "expanded" : "collapsed"
    root.dataset.drawer = next
    document.cookie = `domovoy_drawer=${next}; path=/; max-age=31536000; samesite=lax`
  } else {
    liveSocket.execJS(drawer, drawer.getAttribute("aria-modal") === "true" ? drawer.dataset.close : drawer.dataset.open)
  }
})
// While the overlay drawer is open, Escape closes only it, and Undo doesn't reach the hidden composer.
window.addEventListener("keydown", e => {
  const drawer = document.querySelector("#dashboard-drawer[aria-modal='true']")
  if (!drawer) return
  const undo = (e.metaKey || e.ctrlKey) && e.key?.toLowerCase() === "z"
  if (e.key !== "Escape" && !undo) return
  e.preventDefault()
  e.stopImmediatePropagation()
  if (e.key === "Escape") liveSocket.execJS(drawer, drawer.dataset.close)
}, {capture: true})
// Widening past the overlay breakpoint with the overlay open would leave main inert behind a hidden scrim.
matchMedia("(width >= 48rem)").addEventListener("change", ({matches}) => {
  const drawer = document.querySelector("#dashboard-drawer[aria-modal='true']")
  if (matches && drawer) liveSocket.execJS(drawer, drawer.dataset.close)
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#e6c878"}, shadowColor: "rgba(230, 200, 120, .35)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

